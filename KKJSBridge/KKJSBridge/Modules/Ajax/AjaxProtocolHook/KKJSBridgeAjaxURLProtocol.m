//
//  KKJSBridgeAjaxURLProtocol.m
//  KKJSBridge
//
//  Created by karos li on 2020/6/20.
//

#import "KKJSBridgeAjaxURLProtocol.h"
#import <CFNetwork/CFNetwork.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import "KKJSBridgeAjaxBodyHelper.h"
#import "KKJSBridgeXMLBodyCacheRequest.h"
#import "KKJSBridgeConfig.h"
#import "KKJSBridgeAjaxDelegate.h"
#import "KKJSBridgeSwizzle.h"
#import "KKWebViewCookieManager.h"

typedef CFHTTPMessageRef (*KKJSBridgeURLResponseGetHTTPResponse)(CFURLRef response);

static NSString * const kKKJSBridgeNSURLProtocolKey = @"kKKJSBridgeNSURLProtocolKey";
static NSString * const kKKJSBridgeRequestId = @"KKJSBridge-RequestId";
static NSString * const kKKJSBridgeUrlRequestIdRegex = @"^.*?[&|\\?|%3f]?KKJSBridge-RequestId[=|%3d](\\d+).*?$";
static NSString * const kKKJSBridgeUrlRequestIdPairRegex = @"^.*?([&|\\?|%3f]?KKJSBridge-RequestId[=|%3d]\\d+).*?$";
static NSString * const kKKJSBridgeOpenUrlRequestIdRegex = @"^.*#%5E%5E%5E%5E(\\d+)%5E%5E%5E%5E$";
static NSString * const kKKJSBridgeOpenUrlRequestIdPairRegex = @"^.*(#%5E%5E%5E%5E\\d+%5E%5E%5E%5E)$";
static NSString * const kKKJSBridgeAjaxRequestHeaderAC = @"Access-Control-Request-Headers";
static NSString * const kKKJSBridgeAjaxResponseHeaderAC = @"Access-Control-Allow-Headers";

@interface KKJSBridgeAjaxURLProtocol () <NSURLSessionDelegate, KKJSBridgeAjaxDelegate>

@property (nonatomic, strong) NSURLSessionDataTask *customTask;
@property (nonatomic, copy) NSString *requestId;
@property (nonatomic, copy) NSString *requestHTTPMethod;

@end

@implementation KKJSBridgeAjaxURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // 看看是否已经处理过了，防止无限循环
    if ([NSURLProtocol propertyForKey:kKKJSBridgeNSURLProtocolKey inRequest:request]) {
        return NO;
    }
    
    /**
     //?KKJSBridge-RequestId=159274166292276828
     链接有 RequestId
     */
    if ([request.URL.absoluteString containsString:kKKJSBridgeRequestId]) {
        return YES;
    }
  
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [super requestIsCacheEquivalent:a toRequest:b];
}

- (instancetype)initWithRequest:(NSURLRequest *)request cachedResponse:(NSCachedURLResponse *)cachedResponse client:(id<NSURLProtocolClient>)client {
    self = [super initWithRequest:request cachedResponse:cachedResponse client:client];
    if (self) {
        
    }
    return self;
}

- (void)startLoading {
    NSMutableURLRequest *mutableReqeust = [[self request] mutableCopy];
    //给我们处理过的请求设置一个标识符, 防止无限循环,
    [NSURLProtocol setProperty:@YES forKey:kKKJSBridgeNSURLProtocolKey inRequest:mutableReqeust];
    
    NSString *requestId;
    //?KKJSBridge-RequestId=159274166292276828
    if ([mutableReqeust.URL.absoluteString containsString:kKKJSBridgeRequestId]) {
        requestId = [self fetchRequestId:mutableReqeust.URL.absoluteString];
        // 移除临时的请求id键值对
        NSString *reqeustPair = [self fetchRequestIdPair:mutableReqeust.URL.absoluteString];
        if (reqeustPair) {
            NSString *absString = [mutableReqeust.URL.absoluteString stringByReplacingOccurrencesOfString:reqeustPair withString:@""];
            mutableReqeust.URL = [NSURL URLWithString:absString];
        }
    }
    
    self.requestId = requestId;
    self.requestHTTPMethod = mutableReqeust.HTTPMethod;
    
    // 同步 cookie。有的时候 KKJSBridge 并不是和 KKWebView 同时被使用，所以 KKJSBridge 需要自己完成 cookie 同步
    // 没有携带 Cookie 时，才附加 Cookie，防止覆盖 WKWebView 中的 Cookie
    if (![mutableReqeust valueForHTTPHeaderField:@"Cookie"]) {
        [KKWebViewCookieManager syncRequestCookie:mutableReqeust];
    }
    
    // 设置 body
    NSDictionary *bodyReqeust = [KKJSBridgeXMLBodyCacheRequest getRequestBody:requestId];
    if (bodyReqeust) {
        // 从把缓存的 body 设置给 request
        [KKJSBridgeAjaxBodyHelper setBodyRequest:bodyReqeust toRequest:mutableReqeust];
    }
    
    if (KKJSBridgeConfig.ajaxDelegateManager && [KKJSBridgeConfig.ajaxDelegateManager respondsToSelector:@selector(dataTaskWithRequest:callbackDelegate:)]) {
        // 实际请求代理外部网络库处理
        self.customTask = [KKJSBridgeConfig.ajaxDelegateManager dataTaskWithRequest:mutableReqeust callbackDelegate:self];
    } else {
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:nil];
        self.customTask = [session dataTaskWithRequest:mutableReqeust];
    }
    
    [self.customTask resume];
}

- (void)stopLoading {
    if (self.customTask != nil) {
        [self.customTask  cancel];
        self.customTask = nil;
    }
    
    [self clearRequestBody];
}

- (void)clearRequestBody {
    /**
     参考
     全部的 method
     http://www.iana.org/assignments/http-methods/http-methods.xhtml
     https://stackoverflow.com/questions/41411152/how-many-http-verbs-are-there
     
     Http 1.1
     https://developer.mozilla.org/zh-CN/docs/Web/HTTP/Methods
     
     HTTP Extensions WebDAV
     http://www.webdav.org/specs/rfc4918.html#http.methods.for.distributed.authoring
     */
    
    // 清除缓存
    // 针对有 body 的 method，才需要清除 body 缓存
    NSArray<NSString *> *methods = @[@"POST", @"PUT", @"DELETE", @"PATCH", @"LOCK", @"PROPFIND", @"PROPPATCH", @"SEARCH"];
    if (self.requestHTTPMethod.length > 0 && [methods containsObject:self.requestHTTPMethod]) {
        [KKJSBridgeXMLBodyCacheRequest deleteRequestBody:self.requestId];
    }
}

#pragma mark - NSURLSessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    // 清除缓存
    [self clearRequestBody];
    
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        [self.client URLProtocolDidFinishLoading:self];
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.client URLProtocol:self didLoadData:data];
}

#pragma mark - KKJSBridgeAjaxDelegate - 处理来自外部网络库的数据
- (void)JSBridgeAjax:(id<KKJSBridgeAjaxDelegate>)ajax didReceiveResponse:(NSURLResponse *)response {
    if (!response) {
        // 兜底处理
        response = [[NSURLResponse alloc] initWithURL:self.request.URL MIMEType:@"application/octet-stream" expectedContentLength:0 textEncodingName:@"utf-8"];
    }
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageAllowed];
}

- (void)JSBridgeAjax:(id<KKJSBridgeAjaxDelegate>)ajax didReceiveData:(NSData *)data {
    [self.client URLProtocol:self didLoadData:data];
}

- (void)JSBridgeAjax:(id<KKJSBridgeAjaxDelegate>)ajax didCompleteWithError:(NSError * _Nullable)error {
    // 清除缓存
    [self clearRequestBody];
    
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        [self.client URLProtocolDidFinishLoading:self];
    }
}

#pragma mark - 请求id相关
- (NSString *)fetchRequestId:(NSString *)url {
    return [self fetchMatchedTextFromUrl:url withRegex:kKKJSBridgeUrlRequestIdRegex];
}

- (NSString *)fetchRequestIdPair:(NSString *)url {
    return [self fetchMatchedTextFromUrl:url withRegex:kKKJSBridgeUrlRequestIdPairRegex];
}

- (NSString *)fetchMatchedTextFromUrl:(NSString *)url withRegex:(NSString *)regexString {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:regexString options:NSRegularExpressionCaseInsensitive error:NULL];
    NSArray *matches = [regex matchesInString:url options:0 range:NSMakeRange(0, url.length)];
    NSString *content;
    for (NSTextCheckingResult *match in matches) {
        for (int i = 0; i < [match numberOfRanges]; i++) {
            //以正则中的(),划分成不同的匹配部分
            content = [url substringWithRange:[match rangeAtIndex:i]];
            if (i == 1) {
                return content;
            }
        }
    }
    
    return content;
}

+ (BOOL)validateRequestId:(NSString *)url withRegex:(NSString *)regexString
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", regexString];
    return [predicate evaluateWithObject:url];
}

#pragma mark - 私有方法
- (NSURLResponse *)appendRequestIdToResponseHeader:(NSURLResponse *)response {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *res = (NSHTTPURLResponse *)response;
        NSMutableDictionary *headers = [res.allHeaderFields mutableCopy];
        if (!headers) {
            headers = [NSMutableDictionary dictionary];
        }
        
        NSMutableString *string = [headers[kKKJSBridgeAjaxResponseHeaderAC] mutableCopy];
        if (string) {
            [string appendFormat:@",%@", kKKJSBridgeRequestId];
        } else {
            string = [kKKJSBridgeRequestId mutableCopy];
        }
        headers[kKKJSBridgeAjaxResponseHeaderAC] = [string copy];
        headers[@"Access-Control-Allow-Credentials"] = @"true";
        headers[@"Access-Control-Allow-Origin"] = @"*";
        headers[@"Access-Control-Allow-Methods"] = @"OPTIONS,GET,POST,PUT,DELETE";
        
        NSHTTPURLResponse *updateRes = [[NSHTTPURLResponse alloc] initWithURL:res.URL statusCode:res.statusCode HTTPVersion:[self getHttpVersionFromResponse:res] headerFields:[headers copy]];
        response = updateRes;
    }
    
    return response;
}

- (NSString *)getHttpVersionFromResponse:(NSURLResponse *)response {
    NSString *version;
    // 获取CFURLResponseGetHTTPResponse的函数实现
    NSString *funName = @"CFURLResponseGetHTTPResponse";
    KKJSBridgeURLResponseGetHTTPResponse originURLResponseGetHTTPResponse = dlsym(RTLD_DEFAULT, [funName UTF8String]);

    SEL theSelector = NSSelectorFromString(@"_CFURLResponse");
    if ([response respondsToSelector:theSelector] &&
        NULL != originURLResponseGetHTTPResponse) {
        // 获取NSURLResponse的_CFURLResponse
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        CFTypeRef cfResponse = CFBridgingRetain([response performSelector:theSelector]);
        #pragma clang diagnostic pop
        
        if (NULL != cfResponse) {
            // 将CFURLResponseRef转化为CFHTTPMessageRef
            CFHTTPMessageRef message = originURLResponseGetHTTPResponse(cfResponse);
            // 获取http协议版本
            CFStringRef cfVersion = CFHTTPMessageCopyVersion(message);
            if (NULL != cfVersion) {
                version = (__bridge NSString *)cfVersion;
                CFRelease(cfVersion);
            }
            CFRelease(cfResponse);
        }
    }

    // 获取失败的话则设置一个默认值
    if (nil == version || ![version isKindOfClass:NSString.class] || version.length == 0) {
        version = @"HTTP/1.1";
    }

    return version;
}

@end
