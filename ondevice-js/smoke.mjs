// node ondevice-js/smoke.mjs — live check against YouTube using the same entry as the app bundle.
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

// BotGuard needs a DOM (the app has WKWebView's); window === globalThis as in the web view.
const dom = new JSDOM('<!DOCTYPE html><html lang="en"><head></head><body></body></html>', { url: 'https://www.youtube.com/', pretendToBeVisual: true });
Object.assign(globalThis, { window: globalThis, document: dom.window.document, location: dom.window.location });
await import('./index.js');

const s = JSON.parse(await globalThis.YT.search('lofi hip hop', 1));
assert.ok(s.videos.length >= 5, `expected >=5 results, got ${s.videos.length}`);
for (const v of s.videos) assert.ok(v.id && v.title && v.thumbnails[0]?.url, `incomplete result ${JSON.stringify(v)}`);
console.log(`search: ${s.videos.length} videos, hasMore=${s.hasMore}, first="${s.videos[0].title}"`);

const p2 = JSON.parse(await globalThis.YT.search('lofi hip hop', 2));
console.log(`search page 2: ${p2.videos.length} videos`);

const v = JSON.parse(await globalThis.YT.video('dQw4w9WgXcQ'));
assert.ok(v.title, 'video has no title');
const url = v.hls ?? v.streams[0]?.url;
assert.ok(url, 'no playable stream');
const r = await fetch(url, { headers: { Range: 'bytes=0-1023' } });
assert.ok([200, 206].includes(r.status), `stream fetch returned ${r.status}`);
console.log(`video: "${v.title}" ${v.duration}s, ${v.hls ? 'HLS manifest' : 'progressive'} -> HTTP ${r.status}`);
const hq = JSON.parse(await globalThis.YT.video('aqz-KE-bpKQ'));
const bestV = hq.streams.filter((x) => x.kind === 'video').sort((a, b) => b.height - a.height)[0];
if (bestV) {
  assert.ok(bestV.height >= 1080, `expected video-only >=1080p, got ${bestV.height}`);
  assert.ok(hq.streams.some((x) => x.kind === 'audio'), 'no audio-only stream');
  assert.ok(bestV.initRange && bestV.indexRange, 'adaptive mp4 has no init/index range');
  const hr = await fetch(bestV.url, { headers: { Range: 'bytes=100000000-100001023' } });
  assert.equal(hr.status, 206, `best video range fetch at 100 MB returned ${hr.status}`);
  console.log(`adaptive: best video ${bestV.height}p ${bestV.mimeType} -> HTTP ${hr.status}`);
} else {
  // Adaptive streams are off (see ADAPTIVE_STREAMS); the muxed stream must play to the end.
  const mux = hq.streams.find((x) => x.kind === 'muxed');
  assert.ok(mux, 'no muxed stream');
  const end = Number((await fetch(mux.url, { method: 'HEAD' })).headers.get('content-length'));
  const mr = await fetch(mux.url, { headers: { Range: `bytes=${end - 1024}-${end - 1}` } });
  assert.equal(mr.status, 206, `muxed range fetch at end returned ${mr.status}`);
  console.log(`muxed: itag ${mux.itag} ${mux.height}p, last KB of ${end} -> HTTP ${mr.status}`);
}
const ch = JSON.parse(await globalThis.YT.channel('UCuAXFkgsw1L7xaCfnd5JJOw'));
assert.ok(ch.name, 'channel has no name');
const cv = JSON.parse(await globalThis.YT.channelVideos('UCuAXFkgsw1L7xaCfnd5JJOw', ''));
assert.ok(cv.videos.length >= 10, `expected >=10 channel videos, got ${cv.videos.length}`);
for (const x of cv.videos) assert.ok(x.id && x.title && x.thumbnails[0]?.url, `incomplete channel video ${JSON.stringify(x)}`);
assert.ok(cv.continuation, 'channel videos have no continuation');
const cv2 = JSON.parse(await globalThis.YT.channelVideos('UCuAXFkgsw1L7xaCfnd5JJOw', cv.continuation));
assert.ok(cv2.videos.length >= 1, 'channel videos page 2 is empty');
console.log(`channel: "${ch.name}" ${ch.subscriberCount} subs, ${cv.videos.length} videos, page 2: ${cv2.videos.length}, first="${cv.videos[0].title}" ${cv.videos[0].duration}s ${cv.videos[0].viewCount} views ${cv.videos[0].publishedText}`);
const shorts = JSON.parse(await globalThis.YT.channelShorts('UCuAXFkgsw1L7xaCfnd5JJOw', ''));
const streams = JSON.parse(await globalThis.YT.channelStreams('UCuAXFkgsw1L7xaCfnd5JJOw', ''));
const pls = JSON.parse(await globalThis.YT.channelPlaylists('UCuAXFkgsw1L7xaCfnd5JJOw', ''));
const pl = pls.playlists[0] && JSON.parse(await globalThis.YT.playlist(pls.playlists[0].id));
console.log(`shorts: ${shorts.videos.length} ("${shorts.videos[0]?.title}"), streams: ${streams.videos.length}, playlists: ${pls.playlists.length} (${pls.playlists[0]?.videoCount} videos), first playlist "${pl?.title}" ${pl?.videos.length} videos`);
console.log('smoke OK');
process.exit(0);
