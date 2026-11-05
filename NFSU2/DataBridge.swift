import SwiftUI
import WebKit

struct OPFSEntry {
    let p: String          // path under the page's storage root, e.g. "cache/GLOBALA.BUN.42094976.1730000000"
    let s: Int64
    let complete: Bool     // cache data file: every block is there (other files: true)
    let current: Bool      // cache file the server's file list still names (false: left over from an older version)
}

struct VerifyResult {
    var missing = 0, partial = 0, bad = 0, orphans = 0
    var freed: Int64 = 0
    var complete: Bool { missing == 0 && partial == 0 && bad == 0 }
}

struct BridgeError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Reads and writes the page's own storage (the game data cache and the saves) from native code, through a
/// hidden web view on the game's origin, so the game data can be copied to and from a folder on the device.
@MainActor
final class OPFSBridge: NSObject, ObservableObject, WKNavigationDelegate {
    let web: WKWebView
    private let token: String
    private var loaded = false
    private var loadCont: CheckedContinuation<Void, Error>?

    init(token: String) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()               // the storage the game itself uses
        cfg.limitsNavigationsToAppBoundDomains = true
        web = WKWebView(frame: .zero, configuration: cfg)
        self.token = token
        super.init()
        web.navigationDelegate = self
    }

    /// Loads a tiny page of the game's origin (the file list) so its storage can be reached.
    func prepare() async throws {
        if loaded { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            installSessionCookie(on: web.configuration.websiteDataStore.httpCookieStore, token: token) { c.resume() }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadCont = c
            web.load(URLRequest(url: URL(string: kServer + "data-manifest")!))
        }
        loaded = true
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.loadCont?.resume(); self.loadCont = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.loadCont?.resume(throwing: error); self.loadCont = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.loadCont?.resume(throwing: error); self.loadCont = nil }
    }

    private func js(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        do { return try await web.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page) }
        catch {
            let m = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            throw BridgeError(m ?? error.localizedDescription)
        }
    }

    // ------------------------------------------------------------- listing --
    func list() async throws -> [OPFSEntry] {
        let r = try await js(Self.listJS) as? [[String: Any]] ?? []
        return r.compactMap { d in
            guard let p = d["p"] as? String, let s = (d["s"] as? NSNumber)?.int64Value else { return nil }
            return OPFSEntry(p: p, s: s, complete: (d["c"] as? Bool) ?? true, current: (d["cur"] as? Bool) ?? true)
        }
    }

    /// Base64 of bytes off ..< off+len of a stored file.
    func read(_ p: String, offset: Int64, length: Int64) async throws -> String {
        guard let s = try await js(Self.readJS, ["p": p, "off": offset, "len": length]) as? String
        else { throw BridgeError("Couldn't read \(p)") }
        return s
    }

    func beginWrite(_ p: String) async throws { _ = try await js(Self.beginJS, ["p": p]) }
    func write(_ b64: String) async throws { _ = try await js(Self.writeJS, ["b64": b64]) }
    func endWrite() async throws { _ = try await js("await window.__nfsuW.close(); window.__nfsuW=null; return true;") }
    func abortWrite() async { _ = try? await js("try{if(window.__nfsuW){await window.__nfsuW.abort();window.__nfsuW=null}}catch(e){} return true;") }

    /// Checks the cache against the server's file list; del: also deletes what an older version left behind.
    func verify(deleteOrphans del: Bool) async throws -> VerifyResult {
        guard let d = try await js(Self.verifyJS, ["del": del]) as? [String: Any] else { throw BridgeError("No answer") }
        var r = VerifyResult()
        r.missing = (d["missing"] as? NSNumber)?.intValue ?? 0
        r.partial = (d["partial"] as? NSNumber)?.intValue ?? 0
        r.bad = (d["bad"] as? NSNumber)?.intValue ?? 0
        r.orphans = (d["orphans"] as? NSNumber)?.intValue ?? 0
        r.freed = (d["freed"] as? NSNumber)?.int64Value ?? 0
        return r
    }

    /// Throws the whole game data cache away (the saves stay).
    func clearCache() async throws {
        _ = try await js("try{await (await navigator.storage.getDirectory()).removeEntry('cache',{recursive:true})}catch(e){} return true;")
    }

    // ------------------------------------------------------------- scripts --
    private static let listJS = """
    const BL=1048576;
    const key=f=>f.p.replace(/[^A-Za-z0-9._-]/g,'_')+'.'+(f.s??0)+'.'+(f.m??0);
    let cur=null;
    try{const r=await fetch('/data-manifest',{cache:'no-cache'}); if(r.ok){const m=await r.json(); cur=new Set(m.files.filter(f=>!f.d).map(key));}}catch(e){}
    const out=[];
    async function walk(dir,prefix){
      const names=new Map();
      for await (const [n,h] of dir.entries()) names.set(n,h);
      for(const [n,h] of names){
        if(h.kind==='directory'){ await walk(h,prefix+n+'/'); continue; }
        const f=await h.getFile(); const e={p:prefix+n,s:f.size,c:true,cur:true};
        if(prefix==='cache/'){
          const base=n.endsWith('.have')?n.slice(0,-5):n;
          e.cur=cur?cur.has(base):true;
          if(!n.endsWith('.have')){
            const hh=names.get(n+'.have'); e.c=false;
            if(hh){ const mp=new Uint8Array(await (await hh.getFile()).arrayBuffer()); let ok=mp.length===Math.ceil(f.size/BL); if(ok) for(const b of mp) if(!b){ok=false;break;} e.c=ok; }
          }
        }
        out.push(e);
      }
    }
    await walk(await navigator.storage.getDirectory(),'');
    return out;
    """

    private static let readJS = """
    const parts=p.split('/'); let d=await navigator.storage.getDirectory();
    for(const x of parts.slice(0,-1)) d=await d.getDirectoryHandle(x);
    const f=await (await d.getFileHandle(parts[parts.length-1])).getFile();
    const blob=f.slice(off,off+len);
    return await new Promise((res,rej)=>{const fr=new FileReader();fr.onload=()=>{const s=fr.result;res(s.slice(s.indexOf(',')+1))};fr.onerror=()=>rej(fr.error);fr.readAsDataURL(blob)});
    """

    private static let beginJS = """
    const parts=p.split('/'); let d=await navigator.storage.getDirectory();
    for(const x of parts.slice(0,-1)) d=await d.getDirectoryHandle(x,{create:true});
    const fh=await d.getFileHandle(parts[parts.length-1],{create:true});
    if(window.__nfsuW){try{await window.__nfsuW.abort()}catch(e){}}
    window.__nfsuW=await fh.createWritable({keepExistingData:false});
    return true;
    """

    private static let writeJS = """
    const bin=atob(b64); const u=new Uint8Array(bin.length);
    for(let i=0;i<bin.length;i++) u[i]=bin.charCodeAt(i);
    await window.__nfsuW.write(u);
    return true;
    """

    private static let verifyJS = """
    const BL=1048576;
    const key=f=>f.p.replace(/[^A-Za-z0-9._-]/g,'_')+'.'+(f.s??0)+'.'+(f.m??0);
    const r=await fetch('/data-manifest',{cache:'no-cache'}); if(!r.ok) throw new Error('The server did not answer ('+r.status+')');
    const files=(await r.json()).files.filter(f=>!f.d);
    const want=new Map(files.map(f=>[key(f),f.s??0]));
    let missing=0,partial=0,bad=0,orphans=0,freed=0;
    let dir=null; try{dir=await (await navigator.storage.getDirectory()).getDirectoryHandle('cache')}catch(e){}
    if(!dir) return {missing:files.length,partial:0,bad:0,orphans:0,freed:0};
    const have=new Map(); for await (const [n,h] of dir.entries()) if(h.kind==='file') have.set(n,h);
    if(del) for(const [n,h] of have){ const base=n.endsWith('.have')?n.slice(0,-5):n;
      if(!want.has(base)){ try{const s=(await h.getFile()).size; await dir.removeEntry(n); have.delete(n); orphans++; freed+=s}catch(e){} } }
    for(const [k,size] of want){
      const hh=have.get(k+'.have'); if(!have.has(k)||!hh){missing++;continue}
      const mp=new Uint8Array(await (await hh.getFile()).arrayBuffer()); const nb=Math.ceil(size/BL);
      if(mp.length!==nb){ if(del){try{await dir.removeEntry(k+'.have');await dir.removeEntry(k)}catch(e){}} bad++; continue }
      let c=0; for(const b of mp) if(b) c++; if(c<nb) partial++;
    }
    return {missing,partial,bad,orphans,freed};
    """
}

/// Keeps the bridge's web view alive in the view tree (a view that is not in one gets paused by iOS).
struct BridgeHost: UIViewRepresentable {
    let bridge: OPFSBridge
    func makeUIView(context: Context) -> WKWebView { bridge.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
