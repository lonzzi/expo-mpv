#import "ExpoMpvFontDecoder.h"
#include "../cpp/fonts/FontDecoder.h"

@implementation ExpoMpvFontDecoder
+ (NSArray<NSString *> *)fontFamilies:(NSString *)path error:(NSError **)error {
  try {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (const auto &family : expo_mpv::fontFamilies(path.UTF8String))
      [result addObject:[NSString stringWithUTF8String:family.c_str()]];
    return result;
  } catch (const std::exception &exception) {
    if (error) *error = [NSError errorWithDomain:@"ExpoMpvFonts" code:1 userInfo:@{
      NSLocalizedDescriptionKey: @(exception.what())
    }];
    return nil;
  }
}
+ (BOOL)decodeInput:(NSString *)input output:(NSString *)output error:(NSError **)error {
  try {
    expo_mpv::decodeWoff2(input.UTF8String, output.UTF8String);
    return YES;
  } catch (const std::exception &exception) {
    if (error) *error = [NSError errorWithDomain:@"ExpoMpvFonts" code:1 userInfo:@{
      NSLocalizedDescriptionKey: @(exception.what())
    }];
    return NO;
  }
}
@end
