#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
int main(int argc,const char **argv) { @autoreleasepool {
 if(argc!=2||SecKeychainSetUserInteractionAllowed(false)!=errSecSuccess)return 2;
 NSData *input=[NSData dataWithContentsOfFile:@(argv[1])];if(!input||input.length>16384)return 3;
 NSArray *records=[NSJSONSerialization JSONObjectWithData:input options:0 error:NULL];if(![records isKindOfClass:NSArray.class]||records.count!=2)return 4;
 NSMutableArray *results=[NSMutableArray new];
 for(NSDictionary *record in records){
  NSString *root=record[@"qa_root"],*service=record[@"service"],*account=record[@"account"];
  if(![root isKindOfClass:NSString.class]||![service isKindOfClass:NSString.class]||![account isKindOfClass:NSString.class])return 5;
  if(![@[@"companion-systems-code10-recovery-qa35",@"companion-systems-code10-recovery2-qa35"] containsObject:root.lastPathComponent])return 6;
  struct stat st;if(lstat(root.fileSystemRepresentation,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&0777)!=0700)return 7;
  if(![root.stringByResolvingSymlinksInPath isEqualToString:root])return 8;
  NSData *path=[root dataUsingEncoding:NSUTF8StringEncoding];unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(path.bytes,(CC_LONG)path.length,digest);NSMutableString *suffix=[NSMutableString new];for(int i=0;i<6;i++)[suffix appendFormat:@"%02x",digest[i]];
  NSString *expected=[@"dev.sloopworks.DroidBridge.companion.v1.qa." stringByAppendingString:suffix];if(![expected isEqualToString:service]||![[NSUUID alloc]initWithUUIDString:account])return 9;
  NSDictionary *state=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"CompanionBroker/state.json"]] options:0 error:NULL];BOOL owned=NO;for(NSDictionary *device in state[@"devices"]){if([[device[@"deviceID"] lowercaseString]isEqualToString:account]&&[device[@"aliases"]isEqualToArray:@[@"emulator-5580"]])owned=YES;}if(!owned||![record[@"phone_trust_revoked"]boolValue])return 10;
  NSData *s=[service dataUsingEncoding:NSUTF8StringEncoding],*a=[account dataUsingEncoding:NSUTF8StringEncoding];SecKeychainItemRef item=NULL;
  // NULL password length/data intentionally requests the item reference only.
  OSStatus found=SecKeychainFindGenericPassword(NULL,(UInt32)s.length,s.bytes,(UInt32)a.length,a.bytes,NULL,NULL,&item);
  OSStatus removed=found==errSecSuccess?SecKeychainItemDelete(item):found;if(item)CFRelease(item);
  SecKeychainItemRef check=NULL;OSStatus after=SecKeychainFindGenericPassword(NULL,(UInt32)s.length,s.bytes,(UInt32)a.length,a.bytes,NULL,NULL,&check);if(check)CFRelease(check);
  [results addObject:@{@"lookup_status":@(found),@"delete_status":@(removed),@"after_status":@(after),@"removed_or_absent":@(after==errSecItemNotFound),@"password_data_requested":@NO}];
 }
 NSData *out=[NSJSONSerialization dataWithJSONObject:@{@"public_legacy_metadata_only_cleanup":@YES,@"interaction_disabled":@YES,@"records":results} options:NSJSONWritingPrettyPrinted error:NULL];fwrite(out.bytes,1,out.length,stdout);fwrite("\n",1,1,stdout);
 return 0;
}}
