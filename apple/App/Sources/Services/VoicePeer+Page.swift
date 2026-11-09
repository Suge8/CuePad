import Foundation

extension VoicePeer {
    /// 先采集再建音频上下文：WebKit 先以 AmbientSound 启动上下文、采集后才切 PlayAndRecord，先采集省掉这次重配置。
    static let page = """
    <!doctype html><html><body><script>
    const audio={echoCancellation:true,noiseSuppression:true,autoGainControl:true};
    const sampleMs=50,quietMs=300,levelThreshold=0.02,iceLimitMs=2000;
    class MediaSession {
      constructor(session,record) {
        this.session=session;this.record=record;this.closed=false;this.tracks=new Set();this.outputs=[];
        this.nodes=[];this.meters=[];this.pcm=[];this.inputMax=0;
        this.aborted=new Promise((_,reject)=>this.abort=()=>reject(new Error('session closed')));
        this.aborted.catch(()=>{});
      }
      post(kind,fields={}) {if(!this.closed) webkit.messageHandlers.peer.postMessage({kind,session:this.session,...fields});}
      async wait(operation) {
        if(this.closed) throw new Error('session closed');
        const value=await Promise.race([operation,this.aborted]);
        if(this.closed) throw new Error('session closed');
        return value;
      }
      own(stream) {
        for(const track of stream.getTracks()) {if(this.closed) track.stop();else this.tracks.add(track);}
        if(this.closed) throw new Error('session closed');
        return stream;
      }
      capture(constraints) {return this.wait(navigator.mediaDevices.getUserMedia({audio:constraints}).then(stream=>this.own(stream)));}
      async microphone(device) {
        let stream=await this.capture(audio);
        if(!device) return stream;
        const inputs=await this.wait(navigator.mediaDevices.enumerateDevices());
        const found=inputs.find(item=>item.kind==='audioinput' && item.label.includes(device));
        stream.getTracks().forEach(track=>track.stop());
        if(!found) throw new Error('requested microphone unavailable');
        return this.capture({...audio,deviceId:{exact:found.deviceId}});
      }
      meter(stream,side) {
        const source=this.ctx.createMediaStreamSource(stream),an=this.ctx.createAnalyser();an.fftSize=1024;source.connect(an);
        this.nodes.push(source,an);const values=new Float32Array(an.fftSize);let loud=false,quietFor=0,span=0;
        this.meters.push(setInterval(()=>{
          if(this.closed) return;
          an.getFloatTimeDomainData(values);let peak=0;for(const value of values) peak=Math.max(peak,Math.abs(value));
          if(side==='input') this.inputMax=Math.max(this.inputMax,peak);
          this.post('sample',{side,peak});
          if(peak>levelThreshold) {
            quietFor=0;span=Math.max(span,peak);if(!loud){loud=true;this.post('level',{side,loud,peak});}
          } else if(loud && (quietFor+=sampleMs)>=quietMs) {
            loud=false;this.post('level',{side,loud,peak:span});span=0;
          }
        },sampleMs));
      }
      async start(file,device) {
        if(!file) {
          this.track=(await this.microphone(device)).getAudioTracks()[0];this.post('device',{label:this.track.label});
          this.track.addEventListener('ended',()=>this.post('audioInterrupted'));
        }
        this.ctx=new AudioContext({sampleRate:24000});
        this.ctx.onstatechange=()=>{if(this.ctx.state==='interrupted') this.post('audioInterrupted');};
        await this.wait(this.ctx.resume());
        if(file) {
          this.speech=await this.wait(this.ctx.decodeAudioData(Uint8Array.from(atob(file),c=>c.charCodeAt(0)).buffer));
          this.dest=this.ctx.createMediaStreamDestination();this.track=this.own(this.dest.stream).getAudioTracks()[0];
        }
        this.meter(new MediaStream([this.track]),'input');
        this.pc=new RTCPeerConnection();const peer=this.pc;peer.addTrack(this.track);this.channel=peer.createDataChannel('oai-events');
        peer.onconnectionstatechange=()=>{
          if(peer.connectionState==='connected') this.post('connected');
          else if(['failed','disconnected','closed'].includes(peer.connectionState)) this.post('failed');
        };
        peer.ontrack=event=>this.acceptTrack(event);
        await this.wait(peer.setLocalDescription(await this.wait(peer.createOffer())));
        await this.wait(new Promise(done=>{
          if(peer.iceGatheringState==='complete') return done();
          peer.onicegatheringstatechange=()=>{if(peer.iceGatheringState==='complete') done();};this.iceTimer=setTimeout(done,iceLimitMs);
        }));
        clearTimeout(this.iceTimer);return peer.localDescription.sdp;
      }
      acceptTrack(event) {
        const stream=event.streams[0] || new MediaStream([event.track]);
        if(this.closed){stream.getTracks().forEach(track=>track.stop());return;}
        this.own(stream);const output=new Audio();output.autoplay=true;output.muted=this.record;output.srcObject=stream;
        this.outputs.push(output);output.play().catch(()=>this.post('failed'));this.meter(stream,'output');
        if(!this.record) return;
        const tap=this.ctx.createScriptProcessor(1024,1,1);
        tap.onaudioprocess=event=>{
          if(this.closed) return;
          const values=event.inputBuffer.getChannelData(0),samples=new Int16Array(values.length);
          for(let i=0;i<values.length;i++) samples[i]=Math.max(-1,Math.min(1,values[i]))*32767;
          this.pcm.push(samples);
        };
        const source=this.ctx.createMediaStreamSource(stream);source.connect(tap);tap.connect(this.ctx.destination);this.nodes.push(source,tap);
      }
      answer(sdp) {return this.wait(this.pc.setRemoteDescription({type:'answer',sdp}));}
      play() {
        if(this.closed) throw new Error('session closed');
        const input=this.ctx.createBufferSource();input.buffer=this.speech;input.connect(this.dest);
        input.onended=()=>this.post('inputEnded');input.start();this.nodes.push(input);
      }
      dump() {
        let size=0;for(const part of this.pcm) size+=part.length;
        const all=new Int16Array(size);let offset=0;for(const part of this.pcm){all.set(part,offset);offset+=part.length;}
        const bytes=new Uint8Array(all.buffer);let text='';
        for(let i=0;i<bytes.length;i+=32768) text+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(text);
      }
      shut() {
        if(this.closing) return this.closing;
        this.closed=true;this.abort();clearTimeout(this.iceTimer);this.meters.forEach(clearInterval);
        if(this.pc){this.pc.ontrack=null;this.pc.onconnectionstatechange=null;this.pc.onicegatheringstatechange=null;this.pc.close();}
        this.channel?.close();for(const track of this.tracks) track.stop();
        for(const output of this.outputs){output.pause();output.srcObject=null;}
        for(const node of this.nodes){node.onaudioprocess=null;node.onended=null;if(node.stop) node.stop();node.disconnect();}
        this.closing=Promise.resolve(this.ctx?.close()).then(()=>{
          if([...this.tracks].some(track=>track.readyState!=='ended') || (this.pc && this.pc.connectionState!=='closed')
             || (this.ctx && this.ctx.state!=='closed')) throw new Error('shutdown unconfirmed');
          return 'closed';
        });return this.closing;
      }
    }
    let media;
    function start(session,file,device,record) {
      if(media) throw new Error('document already owns a session');
      media=new MediaSession(session,record);return media.start(file,device);
    }
    function shut(){return media ? media.shut() : 'not-started';}
    requestAnimationFrame(()=>webkit.messageHandlers.peer.postMessage({kind:'ready'}));
    </script></body></html>
    """

    static func wav(_ pcm: Data) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let rate: UInt32 = 24000
        var header = Data("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
        header += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))
        header += le(rate) + le(rate * 2) + le(UInt16(2)) + le(UInt16(16))
        return header + Data("data".utf8) + le(UInt32(pcm.count)) + pcm
    }
}
