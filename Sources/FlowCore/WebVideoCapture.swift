import Foundation

/// Browser responses are reduced to video metadata before crossing the WebKit bridge.
public struct WebVideoCandidate: Decodable {
    public let id: String
    public let title: String
    public let duration: Double?
    public let urls: [String]
    public var mediaURL: String? { urls.first(where: DouyinAccess.isMediaURL) }
    public func matches(_ source: String) -> Bool { Input.videoID(source) == id && mediaURL != nil }
    public static func decode(_ value: Any) -> WebVideoCandidate? {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), data.count < 256 * 1024,
              let candidate = try? JSONDecoder().decode(Self.self, from: data),
              candidate.id.range(of: #"^\d+$"#, options: .regularExpression) != nil, candidate.mediaURL != nil else { return nil }
        return candidate
    }
}

public enum WebVideoCapture {
    public static let script = #"""
    (() => {
      if (window.__flowVideoCapture) return;
      const cache = new Map(); const stats={responses:0,items:0,shape:[]}; const parseJSON=JSON.parse;
      const mediaHost = h => ['douyinvod.com','bytecdn.cn','bytecdn.com','ibytedtos.com','pstatp.com','snssdk.com'].some(d => h === d || h.endsWith('.'+d));
      const safeURL = value => {
        try { const u = new URL(value, location.href); if (u.protocol === 'http:') u.protocol='https:';
          return u.protocol === 'https:' && !u.username && !u.password && mediaHost(u.hostname) && !/\.(m3u8|mpd|m4s)(?:\?|$)/i.test(u.href) ? u.href : null;
        } catch (_) { return null; }
      };
      const currentID = () => { const u=new URL(location.href); return (u.pathname.match(/\/(?:share\/|xg\/)?video\/(\d+)/)||[])[1] || u.searchParams.get('modal_id') || u.searchParams.get('aweme_id'); };
      const publish = item => {
        const id=String(item.aweme_id || item.awemeId || item.itemId || (String(item.id)===currentID() ? item.id : '') || ''); const v=item.video;
        if (!/^\d+$/.test(id) || !v) return;
        stats.items++; if(id===currentID()) stats.shape=Object.keys(v).slice(0,40);
        if ([item.is_drm,v.is_drm,v.drm_type].some(x=>x===true || Number(x)>0)) return;
        const urls=[];
        const append = a => { if (!a) return; const list=typeof a==='string' ? [a] : Array.isArray(a) ? a : a.url_list || a.urlList || [a.src || a.url];
          for (const raw of list) { const value=typeof raw==='object' && raw ? raw.src || raw.url : raw; const url=safeURL(value); if (url && !urls.includes(url)) urls.push(url); }
        };
        append(v.play_addr_h264); append(v.playAddrH264); append(v.play_addr); append(v.playAddr);
        for (const b of (v.bit_rate || v.bitRateList || [])) { append(b.play_addr || b.playAddr); }
        if (!urls.length) return;
        const result={id, title:String(item.desc || item.description || document.title || '抖音视频').slice(0,1000),
                      duration:Number.isFinite(Number(v.duration)) ? Number(v.duration)/1000 : null, urls:urls.slice(0,16)};
        const previous=cache.get(id);
        if(previous && previous.title===result.title && previous.duration===result.duration && previous.urls.join('\n')===result.urls.join('\n')) return;
        cache.set(id,result); while(cache.size>30) cache.delete(cache.keys().next().value);
        if (id===currentID()) window.webkit?.messageHandlers?.flowVideo?.postMessage(result);
      };
      const scan = root => {
        stats.responses++; let count=0; const seen=new Set(); const stack=[root];
        while(stack.length && count++<6000) { const value=stack.pop(); if (!value || typeof value!=='object' || seen.has(value)) continue;
          seen.add(value); publish(value); for(const key of Object.keys(value)) { const child=value[key]; if(child && typeof child==='object') stack.push(child); }
        }
      };
      JSON.parse=function(...args) { const value=parseJSON.apply(this,args); const text=args[0];
        if(typeof text==='string' && text.length<8*1024*1024 && /aweme_id|awemeId|playAddr/.test(text) && /play_addr|playAddr/.test(text)) { try{scan(value);}catch(_){} }
        return value;
      };
      const apiURL = value => { try { const u=new URL(value,location.href); return u.protocol==='https:' && /(^|\.)douyin\.com$/.test(u.hostname) && u.pathname.startsWith('/aweme/v1/'); } catch(_) { return false; } };
      if(window.fetch) { const original=window.fetch;
        window.fetch=function(...args) { const pending=original.apply(this,args); const url=typeof args[0]==='string' ? args[0] : args[0]?.url || String(args[0]);
          if(apiURL(url)) pending.then(r=>{ if(r.ok && Number(r.headers.get('Content-Length')||0)<4*1024*1024) r.clone().text().then(t=>{ if(t.length<4*1024*1024) { try { scan(parseJSON(t)); } catch(_){} } }).catch(()=>{}); }).catch(()=>{});
          return pending;
        };
      }
      const originalOpen=XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open=function(method,url,...rest) {
        if(apiURL(url)) this.addEventListener('load',()=>{ try { if(this.status===200) {
          if(this.responseType==='json') scan(this.response); else if(!this.responseType || this.responseType==='text') { const t=this.responseText; if(t.length<4*1024*1024) scan(parseJSON(t)); }
        } } catch(_){} },{once:true});
        return originalOpen.call(this,method,url,...rest);
      };
      const read = () => {
        for(const s of document.querySelectorAll('script[type="application/json"],script#RENDER_DATA,script#__NEXT_DATA__')) { const t=s.textContent; if(t && t.length<4*1024*1024) { try{scan(parseJSON(t));}catch(_){try{scan(parseJSON(decodeURIComponent(t)));}catch(_){}} } }
        for(const key of ['_ROUTER_DATA','__INITIAL_STATE__','__INITIAL_PROPS__']) { try { if(window[key]) scan(window[key]); } catch(_){} }
        const id=currentID();
        const vs=[...document.querySelectorAll('video')].filter(v=>{ const r=v.getBoundingClientRect(); return r.width>0 && r.height>0; });
        const v=vs.find(v=>!v.paused && !v.ended) || (vs.length===1 ? vs[0] : null);
        if(v) { let element=v; for(let depth=0;element && depth<8;depth++,element=element.parentElement) {
          for(const key of Object.keys(element)) { if(key.startsWith('__reactProps$')) scan(element[key]);
            if(key.startsWith('__reactFiber$')) { let fiber=element[key]; for(let i=0;fiber && i<20;i++,fiber=fiber.return) { if(fiber.memoizedProps) scan(fiber.memoizedProps); } }
          }
        } }
        const direct=safeURL(v?.currentSrc || '');
        const found=cache.get(id);
        if(found) return found;
        if(id && direct) return {id,title:document.title || '抖音视频',duration:Number.isFinite(v.duration)?v.duration:null,urls:[direct]};
        return null;
      };
      window.__flowVideoCapture={read,diagnostics:()=>({...stats,cached:cache.size,globals:Object.keys(window).filter(k=>/router|ssr|initial|rehydr/i.test(k)).slice(0,30),scripts:[...document.scripts].map(s=>s.id).filter(Boolean).slice(0,20)})};
      document.addEventListener('DOMContentLoaded',()=>{read();});
    })();
    """#
}
