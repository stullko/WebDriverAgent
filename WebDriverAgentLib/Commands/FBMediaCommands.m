#import "FBMediaCommands.h"

#import <Photos/Photos.h>

#import "FBCommandStatus.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"

/** Bumped whenever this API changes. */
static NSString *const FBMediaApiVersion = @"pod.1";
/** The largest decoded chunk accepted (the pod sends 3 MiB). */
static const NSUInteger FBMediaMaxChunkBytes = 4 * 1024 * 1024;
/** How long a save may take before the pod hears an error. */
static const int64_t FBMediaSaveTimeoutSec = 120;

static NSString *FBMediaAuthorizationName(PHAuthorizationStatus status)
{
  switch (status) {
    case PHAuthorizationStatusNotDetermined: return @"notDetermined";
    case PHAuthorizationStatusRestricted: return @"restricted";
    case PHAuthorizationStatusDenied: return @"denied";
    case PHAuthorizationStatusAuthorized: return @"authorized";
    case PHAuthorizationStatusLimited: return @"limited";
  }
  return @"notDetermined";
}

/** The temp file of an upload; upload ids are the pod's UUIDs, so nothing else can reach the file system. */
static NSString *_Nullable FBMediaUploadPath(id uploadId)
{
  if (![uploadId isKindOfClass:NSString.class]) {
    return nil;
  }
  NSString *s = (NSString *)uploadId;
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9-]{8,64}$" options:0 error:nil];
  if ([re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] != 1) {
    return nil;
  }
  return [NSTemporaryDirectory() stringByAppendingPathComponent:[@"pod-media-" stringByAppendingString:s]];
}

static id<FBResponsePayload> FBMediaInvalid(NSString *message)
{
  return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message traceback:nil]);
}

@implementation FBMediaCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/wda/media/status"].withoutSession respondWithTarget:self action:@selector(handleStatus:)],
    [[FBRoute POST:@"/wda/media/authorize"].withoutSession respondWithTarget:self action:@selector(handleAuthorize:)],
    [[FBRoute POST:@"/wda/media/chunk"].withoutSession respondWithTarget:self action:@selector(handleChunk:)],
    [[FBRoute POST:@"/wda/media/save"].withoutSession respondWithTarget:self action:@selector(handleSave:)],
  ];
}

+ (id<FBResponsePayload>)handleStatus:(FBRouteRequest *)request
{
  PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
  return FBResponseWithObject(@{@"authorization": FBMediaAuthorizationName(status), @"version": FBMediaApiVersion});
}

+ (id<FBResponsePayload>)handleAuthorize:(FBRouteRequest *)request
{
  // answers at once: iOS shows its prompt, which the pod accepts through /alert/accept
  [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status) {}];
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleChunk:(FBRouteRequest *)request
{
  NSString *path = FBMediaUploadPath(request.arguments[@"uploadId"]);
  id offsetArg = request.arguments[@"offset"];
  id dataArg = request.arguments[@"data"];
  if (nil == path || ![offsetArg isKindOfClass:NSNumber.class] || ![dataArg isKindOfClass:NSString.class]) {
    return FBMediaInvalid(@"uploadId, offset and data are required");
  }
  unsigned long long offset = [(NSNumber *)offsetArg unsignedLongLongValue];
  NSData *data = [[NSData alloc] initWithBase64EncodedString:(NSString *)dataArg options:0];
  if (nil == data || 0 == data.length || data.length > FBMediaMaxChunkBytes) {
    return FBMediaInvalid(@"data must be base64 of 1 byte to 4 MiB");
  }
  NSFileManager *fm = NSFileManager.defaultManager;
  if (0 == offset) {
    // a new upload (or one started over): whatever was there goes
    [fm removeItemAtPath:path error:nil];
    [fm createFileAtPath:path contents:nil attributes:nil];
  }
  if (![fm fileExistsAtPath:path]) {
    return FBMediaInvalid([NSString stringWithFormat:@"offset %llu does not match the 0 bytes received", offset]);
  }
  unsigned long long size = [[fm attributesOfItemAtPath:path error:nil] fileSize];
  if (offset != size) {
    return FBMediaInvalid([NSString stringWithFormat:@"offset %llu does not match the %llu bytes received", offset, size]);
  }
  NSError *error;
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:path] error:&error];
  if (nil == handle) {
    return FBResponseWithUnknownError(error);
  }
  BOOL ok = [handle seekToEndReturningOffset:nil error:&error] && [handle writeData:data error:&error];
  [handle closeAndReturnError:nil];
  return ok ? FBResponseWithOK() : FBResponseWithUnknownError(error);
}

+ (id<FBResponsePayload>)handleSave:(FBRouteRequest *)request
{
  NSString *path = FBMediaUploadPath(request.arguments[@"uploadId"]);
  NSString *kind = request.arguments[@"kind"];
  NSString *album = request.arguments[@"album"];
  NSString *filename = request.arguments[@"filename"];
  NSFileManager *fm = NSFileManager.defaultManager;
  if (nil == path || ![fm fileExistsAtPath:path]) {
    return FBMediaInvalid(@"unknown uploadId");
  }
  if (![@[@"photo", @"video"] containsObject:kind]) {
    return FBMediaInvalid(@"kind must be photo or video");
  }
  if (![album isKindOfClass:NSString.class] || 0 == album.length || ![filename isKindOfClass:NSString.class] || 0 == filename.length) {
    return FBMediaInvalid(@"album and filename are required");
  }
  BOOL video = [kind isEqualToString:@"video"];
  // Photos reads the file's type from its extension
  NSString *extension = filename.pathExtension.length > 0 ? filename.pathExtension : (video ? @"mp4" : @"jpg");
  NSString *typed = [path stringByAppendingPathExtension:extension];
  [fm removeItemAtPath:typed error:nil];
  NSError *error;
  if (![fm moveItemAtPath:path toPath:typed error:&error]) {
    return FBResponseWithUnknownError(error);
  }

  __block NSString *localIdentifier = nil;
  __block BOOL saved = NO;
  __block NSError *saveError = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
    PHAssetCreationRequest *create = [PHAssetCreationRequest creationRequestForAsset];
    // now, so the item is the newest in every gallery (Instagram's included)
    create.creationDate = [NSDate date];
    PHAssetResourceCreationOptions *options = [PHAssetResourceCreationOptions new];
    options.originalFilename = filename;
    options.shouldMoveFile = YES;
    [create addResourceWithType:(video ? PHAssetResourceTypeVideo : PHAssetResourceTypePhoto)
                        fileURL:[NSURL fileURLWithPath:typed]
                        options:options];
    PHObjectPlaceholder *placeholder = create.placeholderForCreatedAsset;
    localIdentifier = placeholder.localIdentifier;
    [[self albumChangeRequestNamed:album] addAssets:@[placeholder]];
  } completionHandler:^(BOOL success, NSError *err) {
    saved = success;
    saveError = err;
    dispatch_semaphore_signal(done);
  }];
  long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, FBMediaSaveTimeoutSec * (int64_t)NSEC_PER_SEC));
  [fm removeItemAtPath:typed error:nil];
  if (0 != timedOut) {
    return FBResponseWithUnknownErrorFormat(@"saving to Photos took longer than %lld s", FBMediaSaveTimeoutSec);
  }
  if (!saved) {
    return FBResponseWithUnknownError(saveError);
  }
  return FBResponseWithObject(@{@"localIdentifier": localIdentifier ?: @""});
}

/** The album's change request, creating the album when none has that title. Only inside performChanges. */
+ (PHAssetCollectionChangeRequest *)albumChangeRequestNamed:(NSString *)title
{
  PHFetchOptions *options = [PHFetchOptions new];
  options.predicate = [NSPredicate predicateWithFormat:@"title == %@", title];
  PHAssetCollection *existing = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                         subtype:PHAssetCollectionSubtypeAlbumRegular
                                                                         options:options].firstObject;
  return nil != existing
    ? [PHAssetCollectionChangeRequest changeRequestForAssetCollection:existing]
    : [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:title];
}

@end
