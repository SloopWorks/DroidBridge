import Foundation
import Vision
let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
request.usesLanguageCorrection=false;request.recognitionLanguages=["en-US"]
try VNImageRequestHandler(url:URL(fileURLWithPath:CommandLine.arguments[1])).perform([request])
let rows=(request.results ?? []).compactMap {row -> [String:Any]? in
 guard let text=row.topCandidates(1).first?.string else {return nil}
 let r=row.boundingBox
 return ["text":text,"x":r.midX,"y":1-r.midY,"width":r.width,"height":r.height]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]))
