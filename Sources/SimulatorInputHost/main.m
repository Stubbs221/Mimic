//
//  main.m
//  SimulatorInputHost
//
//  Created by Василий Маслов on 08.10.2026.
// DTUHID wire protocol reference: facebook/idb, MIT (ThirdPartyNotices/idb-LICENSE).
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <xpc/xpc.h>
#import <mach/mach_time.h>
#import <fcntl.h>
#import <errno.h>
#import <unistd.h>

static NSString *service = @"com.apple.coredevice.feature.remote.hid.digitizer";
static xpc_connection_t connection;
static dispatch_queue_t inputQueue;
static dispatch_source_t interruptSource,terminateSource;
static BOOL active = NO, ready = NO;
static NSString *gesture;
static uint64_t sequence = 0, epoch = 1, lastInput = 0;
static double lastX = 0, lastY = 0, width = 1, height = 1;
static void report(NSDictionary *value) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(d.bytes, 1, d.length, stdout); fputc('\n', stdout); fflush(stdout);
}
static xpc_object_t envelope(const char *type, xpc_object_t payload, BOOL barrier) {
    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(msg, "messageType", type);
    xpc_dictionary_set_string(msg, "featureIdentifier", service.UTF8String);
    xpc_dictionary_set_bool(msg, "isBarrier", barrier);
    xpc_dictionary_set_value(msg, "payload", payload); return msg;
}
static void touch(uint64_t phase, double x, double y) {
    xpc_object_t point = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_double(point, "x", x / width); xpc_dictionary_set_double(point, "y", y / height);
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "pointOne", point);
    xpc_dictionary_set_uint64(payload, "eventType", phase);
    xpc_dictionary_set_uint64(payload, "edge", 0); xpc_dictionary_set_uint64(payload, "target", 0);
    xpc_connection_send_message(connection, envelope("IndigoDigitizerEvent", payload, NO));
}
// Cancellation sends an end once, never replays a possibly delivered movement.
static void cancel(NSString *reason) {
    if (active) { touch(2, lastX, lastY); active = NO; gesture = nil; report(@{@"event":@"released", @"reason":reason}); }
}
static void handle(NSDictionary *event) {
    NSString *phase = event[@"phase"]; uint64_t seq = [event[@"sequence"] isKindOfClass:NSNumber.class] ? [event[@"sequence"] unsignedLongLongValue] : 0;
    if ([phase isEqual:@"reset"]) { cancel(@"epoch"); epoch++; sequence = 0; report(@{@"epoch":@(epoch)}); return; }
    for(NSString *key in @[@"sequence",@"epoch",@"x",@"y",@"timestamp"]){if(![event[key] isKindOfClass:NSNumber.class]){report(@{@"sequence":@(seq),@"accepted":@NO,@"error":@"invalidState"});return;}}
    BOOL down = [phase isEqual:@"down"], move = [phase isEqual:@"move"], keepalive = [phase isEqual:@"heartbeat"], up = [phase isEqual:@"up"] || [phase isEqual:@"cancel"];
    double x = [event[@"x"] doubleValue], y = [event[@"y"] doubleValue];
    NSString *gid = event[@"gesture"];
    BOOL valid = ready && (down || move || up || keepalive) && [gid isKindOfClass:NSString.class] && gid.length > 0 && [event[@"x"] isKindOfClass:NSNumber.class] && [event[@"y"] isKindOfClass:NSNumber.class] && [event[@"timestamp"] isKindOfClass:NSNumber.class] && isfinite([event[@"timestamp"] doubleValue]) && seq == sequence + 1 && [event[@"epoch"] unsignedLongLongValue] == epoch && isfinite(x) && isfinite(y) && x >= 0 && x < width && y >= 0 && y < height && (down ? !active : active && [gesture isEqual:gid]);
    if (!valid) { report(@{@"sequence":@(seq), @"accepted":@NO, @"error":@"invalidState"}); return; }
    sequence = seq; lastInput = mach_absolute_time(); lastX = x; lastY = y;
    if (down) { active = YES; gesture = gid; }
    if (!keepalive) touch(down ? 0 : move ? 1 : 2, x, y);
    if (up) { active = NO; gesture = nil; }
    if (up) {
        // A barrier confirms dtuhidd has drained this connection before the
        // coordinator releases the FIFO to an Apple command.
        xpc_object_t barrier = xpc_dictionary_create(NULL,NULL,0);
        xpc_dictionary_set_uint64(barrier,"usageCode",0); xpc_dictionary_set_uint64(barrier,"state",2);
        xpc_connection_send_message_with_reply(connection,envelope("IndigoKeyboardButtonEvent",barrier,YES),inputQueue,^(xpc_object_t reply){
            if (xpc_get_type(reply)==XPC_TYPE_ERROR) { report(@{@"error":@"xpcInterrupted"}); exit(7); }
            report(@{@"sequence":@(seq), @"accepted":@YES});
        });
    } else report(@{@"sequence":@(seq), @"accepted":@YES});
}
int main(int argc, char **argv) { @autoreleasepool {
    signal(SIGPIPE, SIG_IGN);
    if (argc != 3) return 64;
    dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
    Class cls = NSClassFromString(@"SimServiceContext"); NSError *error = nil;
    if (!cls) { report(@{@"error":@"unsupported"}); return 2; }
    id context = ((id(*)(id,SEL,id,NSError**))objc_msgSend)(cls,NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),@(argv[2]),&error);
    id set = ((id(*)(id,SEL,NSError**))objc_msgSend)(context,NSSelectorFromString(@"defaultDeviceSetWithError:"),&error);
    id device = nil;
    for (id candidate in [set valueForKey:@"devices"]) if ([[[candidate valueForKey:@"UDID"] UUIDString] caseInsensitiveCompare:@(argv[1])] == NSOrderedSame) device = candidate;
    if (!device || [[device valueForKey:@"state"] intValue] != 3) { report(@{@"error":@"deviceUnavailable"}); return 2; }
    id type = [device valueForKey:@"deviceType"];
    CGSize size = [[type valueForKey:@"mainScreenSize"] sizeValue]; double scale = [[type valueForKey:@"mainScreenScale"] doubleValue];
    width = size.width / scale; height = size.height / scale;
    if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0) { report(@{@"error":@"geometryUnavailable"}); return 2; }
    mach_port_t port = ((mach_port_t(*)(id,SEL,id,NSError**))objc_msgSend)(device,NSSelectorFromString(@"lookup:error:"),service,&error);
    xpc_object_t (*endpoint)(mach_port_t,uint64_t,uint64_t) = dlsym(RTLD_DEFAULT,"xpc_endpoint_create_mach_port_4sim");
    void (*enable)(xpc_connection_t) = dlsym(RTLD_DEFAULT,"xpc_connection_enable_sim2host_4sim");
    if (!port || !endpoint || !enable) { report(@{@"error":@"xpcUnavailable"}); return 3; }
    connection = xpc_connection_create_from_endpoint(endpoint(port,0,0)); enable(connection);
    dispatch_queue_t queue = dispatch_queue_create("Mimic.SimulatorInput",DISPATCH_QUEUE_SERIAL); inputQueue = queue;
    xpc_connection_set_target_queue(connection,queue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t e){ if (xpc_get_type(e) == XPC_TYPE_ERROR) { active = NO; ready = NO; report(@{@"error":@"xpcInterrupted"}); exit(7); } });
    xpc_connection_resume(connection);
    xpc_object_t key = xpc_dictionary_create(NULL,NULL,0); xpc_dictionary_set_uint64(key,"usageCode",0); xpc_dictionary_set_uint64(key,"state",2);
    xpc_connection_send_message_with_reply(connection,envelope("IndigoKeyboardButtonEvent",key,YES),queue,^(xpc_object_t r){
        if (xpc_get_type(r) == XPC_TYPE_ERROR) { report(@{@"error":@"livenessFailed"}); exit(4); }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),queue,^{ready = YES; report(@{@"ready":@YES,@"width":@(width),@"height":@(height),@"epoch":@(epoch)});});
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),queue,^{if (!ready) { report(@{@"error":@"livenessTimeout"}); exit(5); }});
    __block NSMutableData *buffer = [NSMutableData data];
    fcntl(STDIN_FILENO,F_SETFL,fcntl(STDIN_FILENO,F_GETFL)|O_NONBLOCK);
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,STDIN_FILENO,0,queue);
    dispatch_source_set_event_handler(input,^{
        uint8_t bytes[8192]; ssize_t count=read(STDIN_FILENO,bytes,sizeof(bytes));
        if(count<0&&(errno==EAGAIN||errno==EWOULDBLOCK))return;
        if(count<=0){dispatch_source_cancel(input);cancel(@"eof");dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),queue,^{exit(0);});return;}
        NSData *d=[NSData dataWithBytes:bytes length:(NSUInteger)count];
        if (buffer.length + d.length > 65536) { cancel(@"overflow"); exit(6); }
        [buffer appendData:d];
        while (YES) { const void *p = memchr(buffer.bytes,'\n',buffer.length); if (!p) break; NSUInteger n = (const char*)p-(const char*)buffer.bytes;
            NSData *line = [buffer subdataWithRange:NSMakeRange(0,n)]; [buffer replaceBytesInRange:NSMakeRange(0,n+1) withBytes:NULL length:0];
            id value = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil]; if ([value isKindOfClass:NSDictionary.class]) handle(value);
        }
    }); dispatch_resume(input);
    dispatch_source_t watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
    dispatch_source_set_timer(watchdog,DISPATCH_TIME_NOW,100*NSEC_PER_MSEC,NSEC_PER_MSEC);
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    dispatch_source_set_event_handler(watchdog,^{if(active && (mach_absolute_time()-lastInput)*(double)tb.numer/tb.denom > 1000000000.) cancel(@"watchdog");}); dispatch_resume(watchdog);
    for (int sig=SIGINT;sig<=SIGTERM;sig+=(SIGTERM-SIGINT)) { signal(sig,SIG_IGN); dispatch_source_t s=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,sig,0,queue); if(sig==SIGINT)interruptSource=s;else terminateSource=s; dispatch_source_set_event_handler(s,^{cancel(@"signal");dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),queue,^{exit(0);});}); dispatch_resume(s); }
    dispatch_main();
} }
