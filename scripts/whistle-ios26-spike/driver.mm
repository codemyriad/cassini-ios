// Offline compatibility probe only. No audio session, playback, microphone or network API.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <sys/resource.h>
#include <mach/mach.h>
#include <cmath>
#include <vector>

static NSString *digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *out = [NSMutableString string];
    for (unsigned char byte : bytes) [out appendFormat:@"%02x", byte];
    return out;
}

static NSDictionary *probe(void) {
    for (const char *key : {"NEEDLE_TELEMETRY", "DO_NOT_TRACK", "ORT_DISABLE_TELEMETRY"}) {
        const char *expected = strcmp(key, "NEEDLE_TELEMETRY") == 0 ? "0" : "1";
        setenv(key, expected, 1);
        if (strcmp(getenv(key), expected)) return @{@"error": @"privacy environment"};
    }
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *root = bundle.resourcePath;
    NSData *manifestData = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"manifest.json"]];
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nullptr];
    if (!manifest) return @{@"error": @"manifest missing"};
    NSData *model = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"whistle.cact"] options:NSDataReadingMappedIfSafe error:nullptr];
    if (!model || ![digest(model) isEqual:manifest[@"modelSha256"]]) return @{@"error": @"model hash"};
    NSString *library = [bundle.privateFrameworksPath stringByAppendingPathComponent:@"WhistleProbeRuntime.framework/WhistleProbeRuntime"];
    void *handle = dlopen(library.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) return @{@"error": [NSString stringWithUTF8String:dlerror()]};
    using Load = int (*)(const unsigned char *, unsigned long long);
    using Transcribe = int (*)(const float *, int, const char *, const char *, int, char *, int);
    using LastError = const char *(*)();
    Load load = (Load)dlsym(handle, "needle_load");
    Transcribe transcribe = (Transcribe)dlsym(handle, "needle_transcribe");
    LastError lastError = (LastError)dlsym(handle, "needle_last_error");
    if (!load || !transcribe || !lastError) return @{@"error": @"missing C API"};
    if (load((const unsigned char *)model.bytes, model.length) < 0) return @{@"error": [NSString stringWithUTF8String:lastError()]};
    NSMutableArray *results = [NSMutableArray array];
    for (NSDictionary *fixture in manifest[@"fixtures"]) {
        NSData *pcm = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:fixture[@"file"]]];
        if (!pcm || pcm.length == 0 || pcm.length % sizeof(float) || pcm.length > 16000 * 30 * sizeof(float)
            || ![digest(pcm) isEqual:fixture[@"inputSha256"]]) return @{@"error": @"invalid PCM/hash", @"fixture":fixture[@"file"]};
        const float *samples = (const float *)pcm.bytes;
        for (NSUInteger i = 0; i < pcm.length / sizeof(float); ++i)
            if (!std::isfinite(samples[i]) || std::abs(samples[i]) > 1) return @{@"error": @"nonfinite/out of range PCM"};
        std::vector<char> output(1048576, 0);
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        int count = transcribe(samples, (int)(pcm.length / sizeof(float)), nullptr, nullptr, 1, output.data(), (int)output.size());
        if (count < 0) return @{@"error": [NSString stringWithUTF8String:lastError()], @"fixture": fixture[@"file"]};
        size_t length = strnlen(output.data(), output.size());
        if (length == output.size()) return @{@"error": @"unterminated output"};
        NSData *data = [NSData dataWithBytes:output.data() length:length];
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
        if (!result) return @{@"error": @"invalid JSON output"};
        [results addObject:@{@"file": fixture[@"file"], @"inputSha256": digest(pcm), @"result": result,
                            @"elapsedSeconds": @(CFAbsoluteTimeGetCurrent() - start)}];
    }
    struct rusage usage; getrusage(RUSAGE_SELF, &usage);
    task_vm_info_data_t info; mach_msg_type_number_t size = TASK_VM_INFO_COUNT;
    kern_return_t memoryResult = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &size);
    NSDictionary *report = @{@"osVersion": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"results": results, @"rssHighWaterBytes": @(usage.ru_maxrss),
        @"physicalFootprintBytes": memoryResult == KERN_SUCCESS ? @(info.phys_footprint) : [NSNull null],
        @"scope": @"offline raw PCM engine probe; simulator RSS is not 3 GB device acceptance"};
    // Keep model bytes alive until no engine code can refer to them.
    dlclose(handle);
    (void)model.length;
    return report;
}

@interface ProbeApp : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow *window;
@end
@implementation ProbeApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSDictionary *result = probe();
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nullptr];
            NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"report.json"];
            BOOL saved = [json writeToFile:path atomically:YES];
            fprintf(stdout, "Whistle probe %s: %s\n", result[@"error"] ? "FAILED" : "completed", path.UTF8String);
            fflush(stdout);
            exit(saved && !result[@"error"] ? 0 : 1);
        }
    });
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeApp.class)); }
}
