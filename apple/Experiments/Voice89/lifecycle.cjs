const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const path=process.argv[2] || 'apple/App/Sources/UI/Debug/DebugSplitMedia+Page.swift';
const script=fs.readFileSync(path,'utf8').split('<script>')[1].split('</script>')[0];
const peers=[],contexts=[],attachments=[],messages=[],tracks=[],outputs=[];
let capture, resume, failOffer=false;
function track(){const t={readyState:'live',stop(){this.readyState='ended'}};tracks.push(t);return t;}
function stream(t=track()){return {getTracks:()=>[t],getAudioTracks:()=>[t]};}
const node=()=>({offset:{},connect(){},start(){},stop(){},disconnect(){this.disconnected=true}});
class AC {
 constructor(){this.id=contexts.length+1;this.state='running';this.destination={};contexts.push(this)}
 resume(){return resume ? resume() : Promise.resolve()}
 createMediaStreamDestination(){return {stream:stream()}}
 createConstantSource(){return node()}
 createScriptProcessor(){return node()}
 createMediaStreamSource(){attachments.push(this.id);return node()}
 close(){this.state='closed';return Promise.resolve()}
}
class PC {
 constructor(){peers.push(this);this.iceGatheringState='complete';this.connectionState='new'}
 addTrack(){} createDataChannel(){return {close(){}}}
 async createOffer(){if(failOffer)throw new Error('offer failed');return {}}
 async setLocalDescription(){this.localDescription={sdp:'v=0'}}
 close(){this.connectionState='closed'}
}
class Audio {constructor(){outputs.push(this)}play(){return Promise.resolve()}pause(){this.paused=true}}
const sandbox={AudioContext:AC,RTCPeerConnection:PC,Audio,webkit:{messageHandlers:{probe:{postMessage:x=>messages.push(x)}}},
 requestAnimationFrame(){},setTimeout,clearTimeout,console,MediaStream:class{},navigator:{mediaDevices:{getUserMedia:()=>capture()}}};
vm.createContext(sandbox);vm.runInContext(script,sandbox);
const make=id=>vm.runInContext(`new ProbeSession(${JSON.stringify(id)})`,sandbox);
async function bounded(work){let timer;try{return await Promise.race([work,new Promise((_,reject)=>timer=setTimeout(()=>reject(new Error('hung')),1000))])}finally{clearTimeout(timer)}}
(async()=>{
 const old=make('old');await old.start(false,null);const oldTrackCallback=peers[0].ontrack;await old.shut();
 const current=make('new');await current.start(false,null);const late=track();oldTrackCallback({streams:[stream(late)]});
 assert.deepEqual(attachments,[]);assert.equal(late.readyState,'ended');assert.equal(contexts[1].state,'running');
 console.log('PASS saved old ontrack cannot attach to new context; late old track stopped');
 const output=track();peers[1].ontrack({streams:[stream(output)]});assert.deepEqual(attachments,[2]);
 await current.shut();assert.equal(output.readyState,'ended');assert.equal(outputs[0].paused,true);assert.equal(contexts[1].state,'closed');
 console.log('PASS normal explicit shutdown stops input/output tracks, peer and audio context');
 let releaseCapture, entered;const enteredCapture=new Promise(r=>entered=r);
 capture=()=>{entered();return new Promise(r=>releaseCapture=r)};
 const pending=make('permission');const starting=pending.start(true,null);await enteredCapture;
 await pending.shut();await bounded(assert.rejects(starting,/session closed/));
 const lateCapture=track();releaseCapture(stream(lateCapture));await new Promise(setImmediate);
 assert.equal(lateCapture.readyState,'ended');
 console.log('PASS pending capture rejects on close before permission completes; late capture stopped');
 resume=()=>new Promise(()=>{});const js=make('pending-js');const blocked=js.start(false,null);
 await js.shut();await bounded(assert.rejects(blocked,/session closed/));resume=null;
 console.log('PASS pending WebAudio operation rejects immediately on session close');
 failOffer=true;const failed=make('failure');await assert.rejects(failed.start(false,null),/offer failed/);await failed.shut();
 assert.equal(failed.track.readyState,'ended');assert.equal(failed.pc.connectionState,'closed');assert.equal(failed.ctx.state,'closed');
 console.log('PASS exception cleanup explicitly closes acquired resources');
})().catch(error=>{console.error(error);process.exitCode=1});
