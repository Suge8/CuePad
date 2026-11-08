#if DEBUG && os(iOS)
extension DebugSplitMedia {
    static let page = """
    <!doctype html><html><body><script>
    const post = (kind, detail='', session='') => webkit.messageHandlers.probe.postMessage({kind,detail,session});
    let pc, ctx, track, out, tap, dest, speech, source, pcm=[], peak=0, playback='pending';
    async function start(microphone, session, file) {
      pcm=[]; peak=0; playback='pending';
      ctx=new AudioContext({sampleRate:24000}); await ctx.resume();
      if(microphone) {
        const stream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true}});
        track=stream.getAudioTracks()[0];
        const settings=track.getSettings();
        post('input',JSON.stringify({state:track.readyState,enabled:track.enabled,muted:track.muted,
          sampleRate:settings.sampleRate,echoCancellation:settings.echoCancellation,
          noiseSuppression:settings.noiseSuppression,autoGainControl:settings.autoGainControl}),session);
      } else {
        dest=ctx.createMediaStreamDestination(); track=dest.stream.getAudioTracks()[0];
        if(file) speech=await ctx.decodeAudioData(Uint8Array.from(atob(file),c=>c.charCodeAt(0)).buffer);
        source=ctx.createConstantSource(); source.offset.value=0; source.connect(dest); source.start();
      }
      const peer=new RTCPeerConnection(); pc=peer;
      peer.addTrack(track);
      const channel=peer.createDataChannel('oai-events');
      channel.onopen=()=>post('data-open','',session);
      // 不把数据通道正文送日志；它不承担 Mac 控制。
      channel.onmessage=()=>{};
      peer.onconnectionstatechange=()=>post(peer.connectionState==='connected'?'connected':'state',peer.connectionState,session);
      peer.ontrack=e=>{
        const stream=e.streams[0] || new MediaStream([e.track]);
        out=new Audio(); out.autoplay=true; out.muted=true; out.srcObject=stream;
        out.play().then(()=>{playback='resolved';post('output-play','muted-recording',session);},()=>{playback='rejected';post('error','play-rejected',session);});
        tap=ctx.createScriptProcessor(1024,1,1);
        tap.onaudioprocess=ev=>{
          const values=ev.inputBuffer.getChannelData(0), samples=new Int16Array(values.length);
          for(let i=0;i<values.length;i++) {peak=Math.max(peak,Math.abs(values[i]));samples[i]=Math.max(-1,Math.min(1,values[i]))*32767;}
          pcm.push(samples);
        };
        ctx.createMediaStreamSource(stream).connect(tap); tap.connect(ctx.destination);
      };
      await peer.setLocalDescription(await peer.createOffer());
      await new Promise(done=>{
        if(peer.iceGatheringState==='complete') return done();
        peer.onicegatheringstatechange=()=>{if(peer.iceGatheringState==='complete') done();};
        setTimeout(done,2000);
      });
      return peer.localDescription.sdp;
    }
    function play() {
      if(!speech) return 'microphone';
      const input=ctx.createBufferSource(); input.buffer=speech; input.connect(dest); input.start(); return 'file-started';
    }
    async function snapshot() {
      const result={connection:pc.connectionState,context:ctx.state,track:track.readyState,playback,outputPeak:peak,inbound:[],outbound:[]};
      for(const stat of (await pc.getStats()).values()) {
        if(stat.type==='inbound-rtp' && stat.kind==='audio') result.inbound.push({packets:stat.packetsReceived,bytes:stat.bytesReceived,energy:stat.totalAudioEnergy,samples:stat.totalSamplesReceived});
        if(stat.type==='outbound-rtp' && stat.kind==='audio') result.outbound.push({packets:stat.packetsSent,bytes:stat.bytesSent});
      }
      return result;
    }
    function dump() {
      let size=0;for(const part of pcm) size+=part.length;
      const all=new Int16Array(size);let offset=0;
      for(const part of pcm){all.set(part,offset);offset+=part.length;}
      const bytes=new Uint8Array(all.buffer);let text='';
      for(let i=0;i<bytes.length;i+=32768) text+=String.fromCharCode(...bytes.subarray(i,i+32768));
      return btoa(text);
    }
    async function shut() {
      track.stop(); pc.close(); out?.pause(); if(out) out.srcObject=null;
      tap?.disconnect(); await ctx.close();
      return JSON.stringify({connection:pc.connectionState,track:track.readyState,context:ctx.state});
    }
    requestAnimationFrame(()=>post('ready'));
    </script></body></html>
    """
}
#endif
