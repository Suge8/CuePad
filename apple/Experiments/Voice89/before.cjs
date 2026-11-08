const fs=require('fs'), vm=require('vm');
const file=fs.readFileSync(process.argv[2] || 'apple/App/Sources/UI/Debug/DebugSplitMedia+Page.swift','utf8');
const script=file.split('<script>')[1].split('</script>')[0];
const peers=[], contexts=[], messages=[];
class AC { constructor(){this.id=contexts.length+1;contexts.push(this);this.state='running';this.destination={};} async resume(){} createMediaStreamDestination(){return {stream:{getAudioTracks:()=>[{stop(){},readyState:'live'}]}}} createConstantSource(){return {offset:{},connect(){},start(){}}} createScriptProcessor(){return {connect(){},disconnect(){}}} createMediaStreamSource(){console.log('old track callback attached to context',this.id);return {connect(){}}} async close(){this.state='closed'} }
class PC {constructor(){peers.push(this);this.iceGatheringState='complete';this.connectionState='new'} addTrack(){} createDataChannel(){return {}} async createOffer(){return {}} async setLocalDescription(){this.localDescription={sdp:'v=0'}} close(){this.connectionState='closed'}}
class Audio {play(){return Promise.resolve()} pause(){}}
const sandbox={AudioContext:AC,RTCPeerConnection:PC,Audio,webkit:{messageHandlers:{probe:{postMessage:x=>messages.push(x)}}},requestAnimationFrame(){},setTimeout,console,MediaStream:class{}};
vm.createContext(sandbox);vm.runInContext(script,sandbox);
(async()=>{await sandbox.start(false,'old',null);await sandbox.shut();await sandbox.start(false,'new',null);peers[0].ontrack({streams:[{}]});await Promise.resolve();console.log('posted session',messages.at(-1).session);})().catch(console.error);
