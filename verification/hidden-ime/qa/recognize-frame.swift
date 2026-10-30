import Foundation
import Vision
let url=URL(fileURLWithPath:CommandLine.arguments[1])
let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=false;request.recognitionLanguages=["en-US"]
try VNImageRequestHandler(url:url).perform([request])
let rows=(request.results ?? []).compactMap {row -> (String,CGRect)? in row.topCandidates(1).first.map {($0.string,row.boundingBox)}}
let compact=rows.map {$0.0.replacingOccurrences(of:" ",with:"")}.joined(separator:"\n")
let pattern=try NSRegularExpression(pattern:#"(\d{3,4})[x×](\d{3,4})"#)
var result:[String:Any]=["texts":rows.map {$0.0}]
if let match=pattern.firstMatch(in:compact,range:NSRange(compact.startIndex...,in:compact)),let w=Range(match.range(at:1),in:compact),let h=Range(match.range(at:2),in:compact) {result["dimensions"]=[Int(compact[w])!,Int(compact[h])!]}
if let upper=rows.first(where:{$0.0.localizedCaseInsensitiveContains("INCREMENT COUNTER")}),let lower=rows.first(where:{$0.0.localizedCaseInsensitiveContains("SECONDARY ACTIVITY")}) {
 let middle=rows.first {$0.1.midY<upper.1.midY && $0.1.midY>lower.1.midY}
 let point=middle?.1 ?? CGRect(x:0.3,y:(upper.1.midY+lower.1.midY)/2,width:0.1,height:0.001)
 result["editorPoint"]=["x":point.midX,"y":1-point.midY]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]))
