#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface ExpoMpvFontDecoder : NSObject
+ (BOOL)decodeInput:(NSString *)input output:(NSString *)output error:(NSError **)error;
+ (nullable NSArray<NSString *> *)fontFamilies:(NSString *)path error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
