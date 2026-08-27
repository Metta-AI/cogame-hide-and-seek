// Execute the broadcast page's own script blocks against a dumb DOM stub and
// fail on the FIRST missing global.
//
// This exists because of a real failure: deleting #viewpanel and the
// first-person inset also deleted the `var $ = C.$;` and `var COG_BASE = ...`
// declarations that happened to sit inside the same regions, and the page
// then died at load with one line — "$ is not defined" — leaving the viewer
// smoke to time out 90 seconds later with `data-replay-loaded=null` and no
// hint about why. A ReferenceError is exactly the class of bug a delete-heavy
// fork of a 4 000-line page produces, and it is invisible to a syntax check.
//
//     node tools/ci/page_smoke.mjs
//
// Exits non-zero if any script block throws anything but a stub artefact.
import fs from 'fs';
const html = fs.readFileSync('client/replay_broadcast.html','utf8');
const common = fs.readFileSync('client/chrome_common.js','utf8');
const blocks = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
// A dumb DOM stub: every element exists and swallows everything.
const mk = () => new Proxy(function(){}, {
  get(t,k){
    if (k==='style') return new Proxy({},{get:()=>()=>{},set:()=>true});
    if (k==='classList') return {add(){},remove(){},toggle(){},contains(){return false}};
    if (k==='dataset') return {};
    if (k==='textContent'||k==='innerHTML'||k==='value'||k==='title') return '';
    if (k==='children'||k==='childNodes') return [];
    if (k==='length') return 0;
    if (k===Symbol.iterator) return [][Symbol.iterator].bind([]);
    if (k===Symbol.toPrimitive) return ()=>0;
    if (k==='toString') return ()=>'';
    if (k==='valueOf') return ()=>0;
    if (k==='getContext') return ()=>mk();
    if (k==='getBoundingClientRect') return ()=>({width:800,height:400,left:0,top:0});
    return mk();
  },
  set(){return true},
  apply(){ return mk(); }
});
const doc = mk();
global.document = doc;
global.window = global;
global.addEventListener = () => {};
global.removeEventListener = () => {};
global.matchMedia = () => ({matches:false, addEventListener(){}});
global.Image = class { set src(v){} get complete(){return false} get naturalWidth(){return 0} };
global.devicePixelRatio = 1;
global.getComputedStyle = () => ({getPropertyValue: () => '0px'});
global.performance = {now: () => 0};
global.location = {search:'', href:'http://x/', protocol:'http:', pathname:'/client/replay'};

global.ResizeObserver = class { observe(){} };
global.requestAnimationFrame = () => 0;
global.setInterval = () => 0; global.setTimeout = () => 0;
global.URLSearchParams = URLSearchParams;
global.WebSocket = class {};
global.HnsStaticReplay = null;
global.BroadcastCore = { create: () => mk() };
try { eval(common); } catch (e) { console.log('chrome_common threw:', e.message); }
let i = 0;
for (const b of blocks) {
  i++;
  try { eval(b); console.log('block', i, 'executed'); }
  catch (e) {
    console.error('block', i, 'THREW:', e.constructor.name, e.message);
    process.exitCode = 1;
  }
}
if (!process.exitCode) console.log('page_smoke: ok');
