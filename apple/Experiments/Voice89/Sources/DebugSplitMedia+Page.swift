#if DEBUG && os(iOS)
extension DebugSplitMedia {
    static let page = """
    <!doctype html><html><body><script>
    class ProbeSession {
      constructor(session) {
        this.session=session; this.closed=false; this.tracks=new Set(); this.outputs=[];
        this.nodes=[]; this.pcm=[]; this.peak=0; this.playback='pending';
        this.aborted=new Promise((_,reject)=>this.abort=()=>reject(new Error('session closed')));
        this.aborted.catch(()=>{});
      }
      post(kind,detail='') {
        if(!this.closed) webkit.messageHandlers.probe.postMessage({kind,detail,session:this.session});
      }
      async wait(operation) {
        if(this.closed) throw new Error('session closed');
        const result=await Promise.race([operation,this.aborted]);
        if(this.closed) throw new Error('session closed');
        return result;
      }
      own(stream) {
        for(const track of stream.getTracks()) {
          if(this.closed) track.stop(); else this.tracks.add(track);
        }
        if(this.closed) throw new Error('session closed');
        return stream;
      }
      async start(microphone,file) {
        this.ctx=new AudioContext({sampleRate:24000});
        await this.wait(this.ctx.resume());
        if(microphone) {
          // 浏览器授权本身不可取消；晚取得的轨道仍必须由原会话立即停掉。
          const capture=navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true}})
            .then(stream=>this.own(stream));
          this.track=(await this.wait(capture)).getAudioTracks()[0];
        } else {
          this.dest=this.ctx.createMediaStreamDestination();
          this.track=this.own(this.dest.stream).getAudioTracks()[0];
          if(file) this.speech=await this.wait(this.ctx.decodeAudioData(Uint8Array.from(atob(file),c=>c.charCodeAt(0)).buffer));
          const source=this.ctx.createConstantSource(); source.offset.value=0; source.connect(this.dest); source.start();
          this.nodes.push(source);
        }
        this.pc=new RTCPeerConnection(); const peer=this.pc;
        peer.addTrack(this.track);
        this.channel=peer.createDataChannel('oai-events');
        this.channel.onopen=()=>this.post('data-open');
        peer.onconnectionstatechange=()=>this.post(peer.connectionState==='connected'?'connected':'state',peer.connectionState);
        peer.ontrack=event=>this.acceptTrack(event);
        await this.wait(peer.setLocalDescription(await this.wait(peer.createOffer())));
        await this.wait(new Promise(done=>{
          if(peer.iceGatheringState==='complete') return done();
          peer.onicegatheringstatechange=()=>{if(peer.iceGatheringState==='complete') done();};
          this.iceTimer=setTimeout(done,2000);
        }));
        clearTimeout(this.iceTimer);
        return peer.localDescription.sdp;
      }
      acceptTrack(event) {
        const stream=event.streams[0] || new MediaStream([event.track]);
        if(this.closed) { stream.getTracks().forEach(track=>track.stop()); return; }
        this.own(stream);
        const output=new Audio(); output.autoplay=true; output.muted=true; output.srcObject=stream;
        this.outputs.push(output);
        output.play().then(()=>{this.playback='resolved';this.post('output-play','muted-recording');},()=>this.post('error','play-rejected'));
        const tap=this.ctx.createScriptProcessor(1024,1,1);
        tap.onaudioprocess=event=>{
          if(this.closed) return;
          const values=event.inputBuffer.getChannelData(0), samples=new Int16Array(values.length);
          for(let i=0;i<values.length;i++) {this.peak=Math.max(this.peak,Math.abs(values[i]));samples[i]=Math.max(-1,Math.min(1,values[i]))*32767;}
          this.pcm.push(samples);
        };
        const source=this.ctx.createMediaStreamSource(stream); source.connect(tap); tap.connect(this.ctx.destination);
        this.nodes.push(source,tap);
      }
      answer(sdp) { return this.wait(this.pc.setRemoteDescription({type:'answer',sdp})); }
      play() {
        if(this.closed) throw new Error('session closed');
        if(!this.speech) return 'microphone';
        const input=this.ctx.createBufferSource(); input.buffer=this.speech; input.connect(this.dest); input.start();
        this.nodes.push(input); return 'file-started';
      }
      async snapshot() {
        const result={connection:this.pc.connectionState,context:this.ctx.state,track:this.track.readyState,
          playback:this.playback,outputPeak:this.peak,inbound:[],outbound:[]};
        for(const stat of (await this.wait(this.pc.getStats())).values()) {
          if(stat.type==='inbound-rtp' && stat.kind==='audio') result.inbound.push({packets:stat.packetsReceived,bytes:stat.bytesReceived,energy:stat.totalAudioEnergy});
          if(stat.type==='outbound-rtp' && stat.kind==='audio') result.outbound.push({packets:stat.packetsSent,bytes:stat.bytesSent});
        }
        return result;
      }
      dump() {
        let size=0;for(const part of this.pcm) size+=part.length;
        const all=new Int16Array(size);let offset=0;
        for(const part of this.pcm){all.set(part,offset);offset+=part.length;}
        const bytes=new Uint8Array(all.buffer);let text='';
        for(let i=0;i<bytes.length;i+=32768) text+=String.fromCharCode(...bytes.subarray(i,i+32768));
        return btoa(text);
      }
      shut() {
        if(this.closing) return this.closing;
        this.closed=true; this.abort(); clearTimeout(this.iceTimer);
        if(this.pc) {this.pc.ontrack=null;this.pc.onconnectionstatechange=null;this.pc.onicegatheringstatechange=null;this.pc.close();}
        if(this.channel) {this.channel.onopen=null;this.channel.close();}
        for(const track of this.tracks) track.stop();
        for(const output of this.outputs) {output.pause();output.srcObject=null;}
        for(const node of this.nodes) {node.onaudioprocess=null;if(node.stop) node.stop();node.disconnect();}
        this.closing=Promise.resolve(this.ctx?.close()).then(()=>JSON.stringify({connection:this.pc?.connectionState,
          tracks:[...this.tracks].map(track=>track.readyState),context:this.ctx?.state}));
        return this.closing;
      }
    }
    // 一个文档只属于一次通话。Swift 每轮创建新文档，不重绑旧回调的资源。
    let media;
    function start(microphone,session,file) {
      if(media) throw new Error('document already owns a session');
      media=new ProbeSession(session); return media.start(microphone,file);
    }
    function shut() { return media ? media.shut() : 'not-started'; }
    requestAnimationFrame(()=>webkit.messageHandlers.probe.postMessage({kind:'ready'}));
    </script></body></html>
    """
}
#endif
