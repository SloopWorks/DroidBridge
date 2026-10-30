import Foundation
import Darwin
@testable import DroidBridgeCore

#if DEBUG
/// Multi-request real TLS peer for broker admission fault/recovery tests. Test
/// credentials and keys live only in an owned temporary directory, then vanish.
final class BrokerAdmissionTLSPeer:@unchecked Sendable {
    let deviceID=UUID().uuidString.lowercased(),trustID=UUID().uuidString.lowercased(),pairingID=UUID()
    let url:URL,serverPin:String
    private let directory:URL,process:Process
    var requestedPaths:[String] { ((try? String(contentsOf:directory.appendingPathComponent("paths.txt"))) ?? "").split(separator:"\n").map(String.init) }
    var stateBodies:[[String:Any]] { ((try? String(contentsOf:directory.appendingPathComponent("states.jsonl"))) ?? "").split(separator:"\n").compactMap {try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]} }
    var blockedRequestSeen:Bool {FileManager.default.fileExists(atPath:directory.appendingPathComponent("blocked").path)}
    func releaseBlocked(){try? Data([1]).write(to:directory.appendingPathComponent("release"))}
    func resetSnapshot(){try? FileManager.default.removeItem(at:directory.appendingPathComponent("snapshot"))}
    init(heartbeat:Bool=false,blockedPath:String="")throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("admission-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        func openssl(_ args:[String])throws{let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/openssl");p.arguments=args;p.standardError=FileHandle.nullDevice;p.standardOutput=FileHandle.nullDevice;try p.run();p.waitUntilExit();guard p.terminationStatus==0 else{throw NSError(domain:"TLS",code:1)}}
        let configuration=directory.appendingPathComponent("cert.cnf")
        try Data("[req]\ndistinguished_name=dn\nx509_extensions=server\nprompt=no\n[dn]\nCN=DroidBridge test\n[server]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n".utf8).write(to:configuration)
        let key=directory.appendingPathComponent("key.pem"),cert=directory.appendingPathComponent("cert.pem"),der=directory.appendingPathComponent("cert.der")
        try openssl(["req","-x509","-newkey","ec","-pkeyopt","ec_paramgen_curve:prime256v1","-pkeyopt","ec_param_enc:named_curve","-sha256","-nodes","-keyout",key.path,"-out",cert.path,"-days","1","-config",configuration.path])
        try openssl(["x509","-in",cert.path,"-outform","DER","-out",der.path]);serverPin=CompanionClient.sha256(try Data(contentsOf:der))
        let source = #"""
        import socket,ssl,pathlib,sys,json,datetime,threading,time
        root=pathlib.Path(sys.argv[1]);device,trust,pair=sys.argv[2:5];heartbeat=sys.argv[5]=='1';blocked=sys.argv[6]
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.minimum_version=ssl.TLSVersion.TLSv1_2
        ctx.set_ecdh_curve('prime256v1')
        ctx.load_cert_chain(str(root/'cert.pem'),str(root/'key.pem'))
        server=socket.socket();server.bind(('127.0.0.1',0));server.listen(8)
        (root/'port.tmp').write_text(str(server.getsockname()[1]));(root/'port.tmp').replace(root/'port')
        def handle(client):
          try:
            client.settimeout(5)
            with ctx.wrap_socket(client,server_side=True) as stream:
              raw=b''
              while len(raw)<278528:
                block=stream.recv(16384)
                if not block:return
                raw+=block
                if b'\r\n\r\n' in raw:
                  heads,body=raw.split(b'\r\n\r\n',1)
                  length=next((int(line.split(b':',1)[1]) for line in heads.split(b'\r\n') if line.lower().startswith(b'content-length:')),0)
                  if len(body)>=length:break
              lines=heads.decode().split('\r\n');method,path,_=lines[0].split(' ')
              path=path.split('?',1)[0]
              headers={line.split(':',1)[0].lower():line.split(':',1)[1] for line in lines[1:] if ':' in line}
              request=headers.get('x-request-id','').strip()
              with (root/'paths.txt').open('a') as record:record.write(path+'\n')
              if path==blocked:
                (root/'blocked').write_text('1');deadline=time.monotonic()+5
                while not (root/'release').exists() and time.monotonic()<deadline:time.sleep(.002)
              status=200
              if path=='/v1/hello':data={'device_id':device,'device_name':'TLS broker fixture','protocol_min':1,'protocol_max':1,'capabilities':['state_heartbeat'] if heartbeat else [],'pairing_available':True}
              elif path=='/v1/pair':data={'pairing_id':pair,'status':'pending','expires_at':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=120)).isoformat().replace('+00:00','Z'),'comparison_code':'ABCDEF12'}
              elif path=='/v1/pair/'+pair:data={'pairing_id':pair,'status':'approved','credential':'A'*43,'trust_id':trust,'device_id':device,'capabilities':[]}
              elif path=='/v1/identity':data={'device_id':device,'trust_id':trust,'protocol':1}
              elif path.startswith('/v1/events'):data={'epoch':device,'events':[],'next_sequence':0,'reset_required':False}
              else:data={'accepted':True}
              error=None
              if path=='/v1/state':
                state=json.loads(body[:length]);
                with (root/'states.jsonl').open('a') as f:f.write(json.dumps(state)+'\n')
                if state.get('unchanged') is True and not (root/'snapshot').exists():status=409;error={'code':'snapshot_required','message':'Snapshot required','retryable':True}
                elif state.get('unchanged') is not True:(root/'snapshot').write_text('1')
              envelope={'protocol':1,'request_id':request}
              envelope['error' if error else 'data']=error if error else data
              response=json.dumps(envelope).encode()
              stream.sendall(b'HTTP/1.1 '+str(status).encode()+b' OK\r\nContent-Type: application/json\r\nContent-Length: '+str(len(response)).encode()+b'\r\nConnection: close\r\n\r\n'+response)
          except (OSError,ValueError,ssl.SSLError):pass
        while True:
          client,_=server.accept();threading.Thread(target=handle,args=(client,),daemon=True).start()
        """#
        let script=directory.appendingPathComponent("peer.py");try Data(source.utf8).write(to:script)
        process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env");process.arguments=["python3",script.path,directory.path,deviceID,trustID,pairingID.uuidString.lowercased(),heartbeat ? "1" : "0",blockedPath];process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice;try process.run()
        let file=directory.appendingPathComponent("port"),deadline=Date().addingTimeInterval(3)
        var ready:UInt16?
        while Date()<deadline {
            if let text=try? String(contentsOf:file),text.utf8.count<=5,text.utf8.allSatisfy({(48...57).contains($0)}),let value=UInt16(text),value>0 {ready=value;break}
            if !process.isRunning {break}
            Thread.sleep(forTimeInterval:0.003)
        }
        guard let port=ready else{let pid=process.processIdentifier;var status:Int32=0;if waitpid(pid,&status,WNOHANG)==0{kill(pid,SIGKILL)};try? FileManager.default.removeItem(at:directory);throw NSError(domain:"TLSPeer",code:2)}
        url=URL(string:"https://127.0.0.1:\(port)")!
    }
    func close(){let pid=process.processIdentifier;var status:Int32=0;if waitpid(pid,&status,WNOHANG)==0{kill(pid,SIGTERM);let end=Date().addingTimeInterval(0.5);while Date()<end,waitpid(pid,&status,WNOHANG)==0{Thread.sleep(forTimeInterval:0.005)};if waitpid(pid,&status,WNOHANG)==0{kill(pid,SIGKILL)}};try? FileManager.default.removeItem(at:directory)}
}
#endif
