// UIImageView+AFNetworking.m
//
// Copyright (c) 2011 Gowalla (http://gowalla.com/)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#include <fts.h>
#include <sys/stat.h>

#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
#import "UIImageView+AFNetworking.h"

@interface AFImageCache ()
@property (nonatomic) NSString *cacheDirectoryName;
@property (nonatomic, strong) NSMutableDictionary *memCaches;
@property (nonatomic) NSInteger diskcacheSize;
@end

@implementation AFImageCache

- (NSUInteger)sizeOfDiskCache
{
    NSUInteger size = 0;
    FTS *fts;
    FTSENT *entry;
    char *paths[] = {
        (char *)[_cacheDirectoryName cStringUsingEncoding:NSUTF8StringEncoding], NULL
    };
    fts = fts_open(paths, 0, NULL);
    while ((entry = fts_read(fts))) {
        if (entry->fts_info & FTS_DP || entry->fts_level == 0) {
            // ignore post-order
            continue;
        }
        if (entry->fts_info & FTS_F) {
            size += entry->fts_statp->st_size;
        }
    }
    fts_close(fts);
    _diskcacheSize = size;
    return size;
}

NSInteger dateModifiedSort(id file1, id file2, void *reverse) {
    NSDictionary *attrs1 = [[NSFileManager defaultManager] attributesOfItemAtPath:file1 error:nil];
    NSDictionary *attrs2 = [[NSFileManager defaultManager] attributesOfItemAtPath:file2 error:nil];
    
    if ((NSInteger *)reverse == NO) {
        return [[attrs2 objectForKey:NSFileModificationDate] compare:[attrs1 objectForKey:NSFileModificationDate]];
    }
    
    return [[attrs1 objectForKey:NSFileModificationDate] compare:[attrs2 objectForKey:NSFileModificationDate]];
}

- (void)cullDiskCache
{
    @synchronized(self){
        [self trimDiskCache];
    }
}

- (void)trimDiskCache
{
    if ([self sizeOfDiskCache] <= 1024*1024*20) return;
    
    int count = 0;
    int size = 0;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSString *path = _cacheDirectoryName;
    
    NSMutableArray *filteredArray = @[].mutableCopy;
    for (NSString *filename in [fileManager enumeratorAtPath:_cacheDirectoryName]) {
        NSString *filepath = [path stringByAppendingPathComponent:filename];
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:filepath
                                                                 error:&error];
        if ([[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeRegular]) {
            count++;
            size += [[attributes objectForKey:NSFileSize] intValue];
            [filteredArray addObject:filepath];
        }
    }
    int reverse = YES;
    NSMutableArray *sortedDirContents = [NSMutableArray arrayWithArray:[filteredArray sortedArrayUsingFunction:dateModifiedSort context:&reverse]];
    while (_diskcacheSize > 1024*1024*8 && [sortedDirContents count] > 0) {
        _diskcacheSize -= [[[[NSFileManager defaultManager] attributesOfItemAtPath:[sortedDirContents lastObject] error:nil] objectForKey:NSFileSize] integerValue];
        [[NSFileManager defaultManager] removeItemAtPath:[sortedDirContents lastObject] error:nil];
        [sortedDirContents removeLastObject];
    }
}

+ (AFImageCache *)sharedImageCache {
    static AFImageCache *_sharedInstance = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        _sharedInstance = [AFImageCache new];
    });
    
    return _sharedInstance;
}

- (void)initDiskCacheDirectories
{
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    BOOL isDirectory = NO;
    BOOL exists = [fileManager fileExistsAtPath:_cacheDirectoryName
                                    isDirectory:&isDirectory];
    if (!exists || !isDirectory) {
        [fileManager createDirectoryAtPath:_cacheDirectoryName
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];
    }
    for (int i = 0; i < 16; i++) {
        for (int j = 0; j < 16; j++) {
            NSString *subDir =
            [NSString stringWithFormat:@"%@/%X%X", _cacheDirectoryName, i, j];
            BOOL isDir = NO;
            BOOL existsSubDir =
            [fileManager fileExistsAtPath:subDir isDirectory:&isDir];
            if (!existsSubDir || !isDir) {
                [fileManager createDirectoryAtPath:subDir
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:nil];
            }
        }
    }
}

- (id)init
{
    self = [super init];
    if (!self) return nil;
    NSArray *paths =
    NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    _cacheDirectoryName = [[paths lastObject] stringByAppendingPathComponent:@"Images"];
    _memCaches = @{}.mutableCopy;
    [self initDiskCacheDirectories];
    
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(removeUnretainedObjects)
                   name:UIApplicationDidReceiveMemoryWarningNotification
                 object:nil];
    return self;
}


- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


#pragma mark - memCache
- (void)removeUnretainedObjects
{
    for (NSString *key in [self.memCaches allKeys]) {
        __weak id safeObject = nil;
        @autoreleasepool {
            safeObject = [self.memCaches objectForKey:key];
            [self.memCaches removeObjectForKey:key];
        }
        
        if (safeObject) {
            [self.memCaches setObject:safeObject forKey:key];
        }
    }
}


#pragma mark - diskCache
- (NSString *)pathForKey:(NSString *)key
{
    NSString *path = [NSString stringWithFormat:@"%@/%@/%@",
                      _cacheDirectoryName,
                      [key substringToIndex:2],
                      key];
    return path;
}


- (void)storeData:(NSData *)data URL:(NSString *)URL
{
    if (!data) return;
    NSString *key = [AFImageCache keyForURL:URL];
    // memory cache
    UIImage *image = [UIImage imageWithData:data];
    if (!image) return;
    [self.memCaches setObject:image forKey:key];
    // disk cache
    [data writeToFile:[self pathForKey:key] atomically:NO];
}


- (UIImage *)cachedImageWithURL:(NSString *)URL
{
    NSString *key = [AFImageCache keyForURL:URL];
    // memory cache
    UIImage *cachedImage = [self.memCaches objectForKey:key];
    if (cachedImage) {
        return cachedImage;
    }
    
    // disk cache
    cachedImage = [UIImage imageWithContentsOfFile:[self pathForKey:key]];
    if (cachedImage) {
        // set memory
        [self.memCaches setObject:cachedImage forKey:key];
    }
    
    return cachedImage;
}


+ (NSString *)keyForURL:(NSString *)URL
{
	if ([URL length] == 0) {
		return nil;
	}
	const char *cStr = [URL UTF8String];
	unsigned char result[16];
	CC_MD5(cStr, (CC_LONG)strlen(cStr), result);
	return [NSString stringWithFormat:@"%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X",
            result[0], result[1], result[2], result[3], result[4], result[5], result[6], result[7],result[8], result[9], result[10], result[11],result[12], result[13], result[14], result[15]];
}
@end

#pragma mark -

static char kAFImageRequestOperationObjectKey;

@interface UIImageView (_AFNetworking)
@property (readwrite, nonatomic, strong, setter = af_setImageRequestOperation:) AFImageRequestOperation *af_imageRequestOperation;
@end

@implementation UIImageView (_AFNetworking)
@dynamic af_imageRequestOperation;
@end

#pragma mark -

@implementation UIImageView (AFNetworking)

- (AFHTTPRequestOperation *)af_imageRequestOperation {
    return (AFHTTPRequestOperation *)objc_getAssociatedObject(self, &kAFImageRequestOperationObjectKey);
}

- (void)af_setImageRequestOperation:(AFImageRequestOperation *)imageRequestOperation {
    objc_setAssociatedObject(self, &kAFImageRequestOperationObjectKey, imageRequestOperation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (NSOperationQueue *)af_sharedImageRequestOperationQueue {
    static NSOperationQueue *_af_imageRequestOperationQueue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _af_imageRequestOperationQueue = [[NSOperationQueue alloc] init];
        [_af_imageRequestOperationQueue setMaxConcurrentOperationCount:NSOperationQueueDefaultMaxConcurrentOperationCount];
    });

    return _af_imageRequestOperationQueue;
}

+ (AFImageCache *)af_sharedImageCache {
    static AFImageCache *_af_imageCache = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        _af_imageCache = [[AFImageCache alloc] init];
    });

    return _af_imageCache;
}

#pragma mark -

- (void)setImageWithURL:(NSURL *)url {
    [self setImageWithURL:url placeholderImage:nil];
}

- (void)setImageWithURL:(NSURL *)url
       placeholderImage:(UIImage *)placeholderImage
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request addValue:@"image/*" forHTTPHeaderField:@"Accept"];

    [self setImageWithURLRequest:request placeholderImage:placeholderImage success:nil failure:nil];
}

- (void)setImageWithURLRequest:(NSURLRequest *)urlRequest
              placeholderImage:(UIImage *)placeholderImage
                       success:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image))success
                       failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error))failure
{
    [self cancelImageRequestOperation];

    UIImage *cachedImage =
    [[AFImageCache sharedImageCache] cachedImageWithURL:urlRequest.URL.absoluteString];

    if (cachedImage) {
        if (success) {
            success(nil, nil, cachedImage);
        } else {
            self.image = cachedImage;
        }

        self.af_imageRequestOperation = nil;
    } else {
        self.image = placeholderImage;

        AFImageRequestOperation *requestOperation = [[AFImageRequestOperation alloc] initWithRequest:urlRequest];
        [requestOperation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
            if ([urlRequest isEqual:[self.af_imageRequestOperation request]]) {
                if (success) {
                    success(operation.request, operation.response, responseObject);
                } else if (responseObject) {
                    self.image = responseObject;
                }

                if (self.af_imageRequestOperation == operation) {
                    self.af_imageRequestOperation = nil;
                }
            }

            [[AFImageCache sharedImageCache] storeData:operation.responseData
                                                   URL:urlRequest.URL.absoluteString];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
            if ([urlRequest isEqual:[self.af_imageRequestOperation request]]) {
                if (failure) {
                    failure(operation.request, operation.response, error);
                }

                if (self.af_imageRequestOperation == operation) {
                    self.af_imageRequestOperation = nil;
                }
            }
        }];

        self.af_imageRequestOperation = requestOperation;

        [[[self class] af_sharedImageRequestOperationQueue] addOperation:self.af_imageRequestOperation];
    }
}

- (void)cancelImageRequestOperation {
    [self.af_imageRequestOperation cancel];
    self.af_imageRequestOperation = nil;
}

@end

#endif
