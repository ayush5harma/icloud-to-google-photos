// gp-bridge: a folder that uploads to Google Photos through GoToHP, the
// upload engine the Gunshot tweak (github.com/tqmane/gunshot, GPL-3.0)
// embeds in Google Photos. Linked into the app by
// `ipa-install-on-mac --dylib gp-bridge.m`.
//
// The tweak drives its engine only from its own UI, and every source that UI
// offers reads the photo library through PhotoKit -- on a Mac, the iCloud
// Photos library, which is exactly what must not receive these files. The
// engine itself imports files: begin(account, resources) -> append(32 KiB
// chunks) -> seal, then uploads the job on its own and reports its state and
// Google's media key (internal/service/{protocol,queue}.go). This does those
// three steps for every file dropped in a folder the app's sandbox can reach:
//
//   <home>/Pictures/Google Photos Upload/     drop photos and videos here
//     Uploaded/        moved here once Google confirmed the upload (media key)
//     Failed/          moved here once the engine gave up (see the ledger)
//     .bridge/
//       ledger.json    file -> job id, state, media key, error, and where the
//                      file was moved ("moved"); the contract a caller (the
//                      iCloud -> Google Photos sync) reads before it deletes
//                      anything from iCloud
//       alive.json     heartbeat: pid, time, engine found, signed in, whether
//                      the engine may upload now ("online": a visible window
//                      and a network), paused, last error
//       request-<id>.json / response-<id>.json
//                      raw engine requests for a caller that needs one
//                      (role "photos"; "configure" runs as "settings")
//
// A caller drops a file under a dot-name and renames it into place (the
// scanner skips dot-names, and waits out anything whose inode changed in the
// last five seconds), a Live Photo's two files renamed back to back. It removes a file from Uploaded/ or Failed/ once it has
// recorded the outcome, and the entry is dropped an hour later; a name dropped
// again after its entry reached Uploaded/ or Failed/ is imported again, which
// is how a caller retries a failure.
//
// ~/Pictures because the installer's com.apple.security.assets.pictures.read-
// write entitlement lets the sandboxed app read and write there, and any
// process outside can without touching another app's container.
//
// The engine uploads only while the app counts as foreground (a visible
// window, active or not; minimised does not) and online; its Wi-Fi-only
// option, on by default, would hold every upload on an Ethernet Mac, so the
// bridge turns that one option off once (a Mac has no cellular data to save).
//
// GunshotRequest(const char *json, const char *role) -> char * (GunshotFree):
// cmd/bridge/main.go. The role gates operations (protocol.go roleAllowed).
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

typedef char *(*gs_request_fn)(const char *json, const char *role);
typedef void (*gs_free_fn)(void *ptr);

static gs_request_fn g_request;
static gs_free_fn g_free;
static NSString *g_root, *g_dir;
static NSMutableDictionary *g_ledger;   // name -> entry
static NSString *g_account, *g_lastError;
static BOOL g_wifiChecked;
static NSData *g_written;                // the ledger as last written
static NSDictionary *g_conditions;       // upload_summary's conditions

static const NSUInteger kChunk = 32768;          // MaxChunk
static const NSTimeInterval kSettle = 5;         // a file untouched this long is complete
// Imports per tick. Each is a begin/append/seal of the whole file on this
// queue, so an unbounded backlog of a few hundred photos held the heartbeat
// and the job states for minutes; the rest wait for the next tick, 3 s later.
static const NSUInteger kImportsPerTick = 20;
static const NSTimeInterval kForget = 3600;      // a consumed entry is dropped this long after its move
static NSSet *image_exts(void) { return [NSSet setWithArray:@[@"jpg", @"jpeg", @"heic", @"heif", @"png", @"gif", @"webp", @"tif", @"tiff", @"dng", @"raw", @"cr2", @"cr3", @"nef", @"arw", @"orf", @"rw2", @"avif", @"bmp"]]; }
static NSSet *video_exts(void) { return [NSSet setWithArray:@[@"mov", @"mp4", @"m4v", @"3gp", @"avi", @"mkv", @"mts", @"m2ts", @"wmv", @"webm"]]; }

static void write_json(NSString *path, id obj) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:NULL];
  if (data) [data writeToFile:path atomically:YES];
}

// One engine call. Returns the reply's "data" (NSNull when empty) or nil on
// failure, recording the failure.
static id call(NSDictionary *request, const char *role) {
  NSData *body = [NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];
  if (!body || !g_request) return nil;
  NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
  char *out = g_request(text.UTF8String, role);
  if (!out) return nil;
  NSData *reply = [NSData dataWithBytes:out length:strlen(out)];
  g_free(out);
  NSDictionary *r = [NSJSONSerialization JSONObjectWithData:reply options:0 error:NULL];
  if (![r isKindOfClass:NSDictionary.class] || ![r[@"ok"] boolValue]) {
    g_lastError = [NSString stringWithFormat:@"%@: %@", request[@"op"], [r isKindOfClass:NSDictionary.class] ? r[@"error"] : @"unreadable reply"];
    return nil;
  }
  return r[@"data"] ?: NSNull.null;
}

static NSString *selected_account(void) {
  NSDictionary *a = call(@{@"op": @"accounts"}, "photos");
  if (![a isKindOfClass:NSDictionary.class]) return nil;
  id sel = a[@"selected"];
  if ([sel isKindOfClass:NSString.class] && [sel length]) return sel;
  NSArray *all = a[@"accounts"];
  if ([all isKindOfClass:NSArray.class] && all.count && [all[0] isKindOfClass:NSDictionary.class]) {
    id email = all[0][@"email"] ?: all[0][@"Email"];
    if ([email isKindOfClass:NSString.class]) return email;
  }
  return nil;
}

// A Mac has no cellular data: Wi-Fi-only would stall every upload over
// Ethernet ("Waiting for Wi-Fi"). Turned off once; everything else as set.
static void relax_wifi_only(void) {
  if (g_wifiChecked) return;
  NSDictionary *o = call(@{@"op": @"options"}, "photos");
  if (![o isKindOfClass:NSDictionary.class]) return;
  g_wifiChecked = YES;
  if (![o[@"wifiOnly"] boolValue]) return;
  NSMutableDictionary *n = [o mutableCopy];
  n[@"wifiOnly"] = @NO;
  call(@{@"op": @"configure", @"options": n}, "settings");
}

static NSString *stem_of(NSString *name) {
  NSString *s = name.stringByDeletingPathExtension;
  if ([s.lowercaseString hasSuffix:@"_hevc"]) s = [s substringToIndex:s.length - 5];   // icloudpd's live-photo video
  return s.lowercaseString;
}

// begin -> append -> seal for one photo or video, or a live photo's pair.
static NSString *import_files(NSArray<NSString *> *names, NSDictionary<NSString *, NSDictionary *> *attrs) {
  NSMutableArray *resources = [NSMutableArray array];
  NSTimeInterval stamp = 0;
  for (NSString *n in names) {
    [resources addObject:@{@"name": n, @"size": attrs[n][NSFileSize]}];
    stamp = MAX(stamp, [attrs[n][NSFileModificationDate] timeIntervalSince1970]);
  }
  NSDictionary *o = call(@{@"op": @"options"}, "photos");
  NSString *quality = [o isKindOfClass:NSDictionary.class] && [o[@"quality"] length] ? o[@"quality"] : @"original";
  NSDictionary *begun = call(@{@"op": @"begin", @"account": g_account, @"quality": quality,
                               @"resources": resources, @"timestamp": @((long long)stamp)}, "photos");
  NSString *jid = [begun isKindOfClass:NSDictionary.class] ? begun[@"id"] : nil;
  if (![jid isKindOfClass:NSString.class]) return nil;
  for (NSUInteger i = 0; i < names.count; i++) {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:[g_root stringByAppendingPathComponent:names[i]]];
    unsigned long long offset = 0;
    for (;;) {
      @autoreleasepool {
        NSData *chunk = [h readDataOfLength:kChunk];
        if (!chunk.length) break;
        if (!call(@{@"op": @"append", @"id": jid, @"index": @(i), @"offset": @(offset),
                    @"data": [chunk base64EncodedStringWithOptions:0]}, "photos")) {
          [h closeFile];
          call(@{@"op": @"cancel", @"id": jid}, "photos");
          return nil;
        }
        offset += chunk.length;
      }
    }
    [h closeFile];
  }
  NSDictionary *sealed = call(@{@"op": @"seal", @"id": jid}, "photos");
  if (!sealed) {
    call(@{@"op": @"cancel", @"id": jid}, "photos");
    return nil;
  }
  // The same bytes as an earlier job (the engine's fingerprint is the sizes
  // and content hashes, not the names): the engine cancels this one and names
  // the earlier job, whose outcome is this file's outcome. Measured
  // 2026-09-16: a re-dropped copy under a new name came back cancelled, and
  // tracking the cancelled id would leave it cancelled forever. A failed
  // earlier job is retried, since a re-drop is how a caller asks for that.
  if ([sealed isKindOfClass:NSDictionary.class] && [sealed[@"duplicate"] boolValue] && [sealed[@"id"] isKindOfClass:NSString.class]) {
    NSDictionary *old = call(@{@"op": @"job", @"id": sealed[@"id"]}, "photos");
    if ([old isKindOfClass:NSDictionary.class] && [old[@"state"] isEqual:@"failed"])
      call(@{@"op": @"retry", @"id": sealed[@"id"]}, "photos");
    return sealed[@"id"];
  }
  return jid;
}

// Moves each file into Uploaded/ or Failed/ and records where it went, which
// is also what marks the entry finished.
static void move_into(NSString *sub, NSArray<NSString *> *names) {
  NSString *dest = [g_root stringByAppendingPathComponent:sub];
  [NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:NULL];
  for (NSString *n in names) {
    NSString *leaf = n;
    if ([NSFileManager.defaultManager fileExistsAtPath:[dest stringByAppendingPathComponent:leaf]])
      leaf = [NSString stringWithFormat:@"%@-%lld.%@", n.stringByDeletingPathExtension,
                                        (long long)NSDate.date.timeIntervalSince1970, n.pathExtension];
    [NSFileManager.defaultManager moveItemAtPath:[g_root stringByAppendingPathComponent:n]
                                          toPath:[dest stringByAppendingPathComponent:leaf] error:NULL];
    NSMutableDictionary *e = g_ledger[n];
    e[@"moved"] = [sub stringByAppendingPathComponent:leaf];
    e[@"movedAt"] = @((long long)NSDate.date.timeIntervalSince1970);
  }
}

// An entry whose file has moved is finished; the same name in the folder again
// is a new drop (a retry), and the caller removing the moved file is the
// signal that the outcome was consumed.
static BOOL finished(NSDictionary *e) { return [e[@"moved"] length] > 0; }

static void forget_consumed(void) {
  long long now = (long long)NSDate.date.timeIntervalSince1970;
  for (NSString *n in g_ledger.allKeys) {
    NSDictionary *e = g_ledger[n];
    if (!finished(e) || now - [e[@"movedAt"] longLongValue] < kForget) continue;
    if (![NSFileManager.defaultManager fileExistsAtPath:[g_root stringByAppendingPathComponent:e[@"moved"]]])
      [g_ledger removeObjectForKey:n];
  }
}

static void scan_folder(void) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableDictionary<NSString *, NSDictionary *> *attrs = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary dictionary];
  NSDate *settled = [NSDate dateWithTimeIntervalSinceNow:-kSettle];
  for (NSString *n in [fm contentsOfDirectoryAtPath:g_root error:NULL]) {
    if ([n hasPrefix:@"."] || (g_ledger[n] && !finished(g_ledger[n]))) continue;
    NSDictionary *a = [fm attributesOfItemAtPath:[g_root stringByAppendingPathComponent:n] error:NULL];
    if (![a[NSFileType] isEqual:NSFileTypeRegular] || [a[NSFileSize] longLongValue] <= 0) continue;
    NSString *ext = n.pathExtension.lowercaseString;
    if (![image_exts() containsObject:ext] && ![video_exts() containsObject:ext]) continue;
    // Settled on the CHANGE time, not the modification time: a caller that
    // keeps the photo's own date (cp -p, which the engine turns into the
    // item's timestamp) hands over a file whose mtime is years old while its
    // bytes are still landing; every write, the date restore and the final
    // rename all bump the ctime. Anything still arriving holds the whole scan,
    // so a Live Photo's still and video are seen together.
    struct stat st;
    if (stat([g_root stringByAppendingPathComponent:n].fileSystemRepresentation, &st) != 0) continue;
    if (st.st_ctimespec.tv_sec > (time_t)settled.timeIntervalSince1970) return;   // still arriving: next tick
    attrs[n] = a;
    NSString *k = stem_of(n);
    if (!groups[k]) groups[k] = [NSMutableArray array];
    [groups[k] addObject:n];
  }
  NSUInteger imports = 0;
  for (NSString *k in [groups.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (imports >= kImportsPerTick) break;
    NSArray *names = [groups[k] sortedArrayUsingSelector:@selector(compare:)];
    // A live photo is one still and one video with the same stem; anything
    // else sharing a stem goes up as separate items.
    NSArray *batches = @[names];
    if (names.count == 2) {
      BOOL a = [image_exts() containsObject:[names[0] pathExtension].lowercaseString];
      BOOL b = [image_exts() containsObject:[names[1] pathExtension].lowercaseString];
      if (a == b) batches = @[@[names[0]], @[names[1]]];
    } else if (names.count > 2) {
      NSMutableArray *singles = [NSMutableArray array];
      for (NSString *n in names) [singles addObject:@[n]];
      batches = singles;
    }
    for (NSArray *batch in batches) {
      imports++;
      NSString *jid = import_files(batch, attrs);
      for (NSString *n in batch)
        g_ledger[n] = [@{@"id": jid ?: @"", @"state": jid ? @"pending" : @"import_failed", @"size": attrs[n][NSFileSize],
                         @"files": batch, @"queued": @((long long)NSDate.date.timeIntervalSince1970)} mutableCopy];
      if (!jid) move_into(@"Failed", batch);
    }
  }
}

static void refresh_jobs(void) {
  NSMutableSet *seen = [NSMutableSet set];
  for (NSString *n in g_ledger.allKeys) {
    NSMutableDictionary *e = g_ledger[n];
    NSString *state = e[@"state"], *jid = e[@"id"];
    if (!jid.length || finished(e) || [seen containsObject:jid]) continue;
    if ([state isEqual:@"completed"] || [state isEqual:@"cancelled"] || [state isEqual:@"import_failed"]) continue;
    [seen addObject:jid];
    NSDictionary *j = call(@{@"op": @"job", @"id": jid}, "photos");
    if (![j isKindOfClass:NSDictionary.class]) continue;
    NSArray *files = e[@"files"] ?: @[n];
    for (NSString *f in files) {
      NSMutableDictionary *x = g_ledger[f];
      x[@"state"] = j[@"state"] ?: @"unknown";
      if ([j[@"mediaKey"] length]) x[@"mediaKey"] = j[@"mediaKey"];
      if ([j[@"error"] length]) x[@"error"] = j[@"error"];
      x[@"attempts"] = j[@"attempts"] ?: @0;
    }
    if ([j[@"state"] isEqual:@"completed"] && [j[@"mediaKey"] length]) {
      for (NSString *f in files) g_ledger[f][@"uploaded"] = @((long long)NSDate.date.timeIntervalSince1970);
      move_into(@"Uploaded", files);
    } else if ([j[@"state"] isEqual:@"failed"] && [j[@"attempts"] intValue] > 0 && !j[@"next"]) {
      move_into(@"Failed", files);
    }
  }
}

static void serve_requests(void) {
  NSFileManager *fm = NSFileManager.defaultManager;
  for (NSString *name in [[fm contentsOfDirectoryAtPath:g_dir error:NULL] sortedArrayUsingSelector:@selector(compare:)]) {
    if (![name hasPrefix:@"request-"] || ![name hasSuffix:@".json"]) continue;
    NSString *path = [g_dir stringByAppendingPathComponent:name];
    NSData *body = [NSData dataWithContentsOfFile:path];
    [fm removeItemAtPath:path error:NULL];
    NSDictionary *req = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    if (![req isKindOfClass:NSDictionary.class]) {
      reply[@"bridgeError"] = @"the request is not a JSON object";
    } else {
      NSData *raw = [NSJSONSerialization dataWithJSONObject:req options:0 error:NULL];
      NSString *text = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
      char *out = g_request(text.UTF8String, [req[@"op"] isEqual:@"configure"] ? "settings" : "photos");
      if (out) {
        id parsed = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:out length:strlen(out)] options:0 error:NULL];
        reply[@"reply"] = parsed ?: @(out);
        g_free(out);
      }
    }
    write_json([g_dir stringByAppendingPathComponent:[NSString stringWithFormat:@"response-%@.json",
                                                      [[name substringFromIndex:8] stringByDeletingPathExtension]]], reply);
  }
}

static void tick(void) {
  if (!g_request) {
    g_request = (gs_request_fn)dlsym(RTLD_DEFAULT, "GunshotRequest");
    g_free = (gs_free_fn)dlsym(RTLD_DEFAULT, "GunshotFree");
  }
  NSFileManager *fm = NSFileManager.defaultManager;
  [fm createDirectoryAtPath:g_dir withIntermediateDirectories:YES attributes:nil error:NULL];
  if (g_request && g_free) {
    serve_requests();
    if (!g_account) g_account = selected_account();
    relax_wifi_only();
    if (g_account) {
      scan_folder();
      refresh_jobs();
      forget_consumed();
    }
    NSDictionary *s = call(@{@"op": @"upload_summary"}, "photos");
    g_conditions = [s isKindOfClass:NSDictionary.class] && [s[@"conditions"] isKindOfClass:NSDictionary.class] ? s[@"conditions"] : nil;
    // Written only when it changed: thousands of entries rewritten every 3 s
    // is disk traffic for nothing. Sorted keys make the comparison stable.
    NSData *now = [NSJSONSerialization dataWithJSONObject:@{@"files": g_ledger} options:NSJSONWritingSortedKeys error:NULL];
    if (now && ![now isEqualToData:g_written]) {
      if ([now writeToFile:[g_dir stringByAppendingPathComponent:@"ledger.json"] atomically:YES]) g_written = now;
    }
  }
  write_json([g_dir stringByAppendingPathComponent:@"alive.json"],
             @{@"pid": @(getpid()), @"time": @((long long)NSDate.date.timeIntervalSince1970), @"engine": g_request ? @YES : @NO,
               @"account": g_account ? @YES : @NO, @"online": g_conditions[@"online"] ?: @NO,
               @"paused": g_conditions[@"paused"] ?: @NO, @"lastError": g_lastError ?: @"", @"folder": g_root});
}

__attribute__((constructor)) static void gp_bridge_start(void) {
  struct passwd *pw = getpwuid(getuid());
  NSString *home = pw && pw->pw_dir ? @(pw->pw_dir) : NSHomeDirectory();
  g_root = [home stringByAppendingPathComponent:@"Pictures/Google Photos Upload"];
  g_dir = [g_root stringByAppendingPathComponent:@".bridge"];
  NSData *prev = [NSData dataWithContentsOfFile:[g_dir stringByAppendingPathComponent:@"ledger.json"]];
  NSDictionary *old = prev ? [NSJSONSerialization JSONObjectWithData:prev options:0 error:NULL][@"files"] : nil;
  g_ledger = [NSMutableDictionary dictionary];
  for (NSString *k in old) if ([old[k] isKindOfClass:NSDictionary.class]) g_ledger[k] = [old[k] mutableCopy];
  static dispatch_source_t timer;
  dispatch_queue_t queue = dispatch_queue_create("gp-bridge", DISPATCH_QUEUE_SERIAL);
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
  // First pass after 8 s: the tweak initialises its engine during launch.
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, NSEC_PER_SEC);
  dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { tick(); } });
  dispatch_resume(timer);
}
