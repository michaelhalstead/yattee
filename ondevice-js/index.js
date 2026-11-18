// On-device YouTube backend for Yattee, run in a hidden WKWebView (see OnDeviceJSRuntime.swift).
// Rebuild the bundled resource after changing this file or bumping youtubei.js:
//   cd ondevice-js && npm ci && npm run build   (writes ../Yattee/Resources/ondevice.js)
import { Innertube, Platform } from 'youtubei.js/web';
import { BotGuardClient } from 'bgutils-js/botguard';
import { WebPoMinter } from 'bgutils-js/webpo';
import { GOOG_API_KEY, parseLooseJSON } from 'bgutils-js/utils';

// Deciphers signature / n params by running the player script in this JS context.
Platform.shim.eval = async (data, env) => {
  const args = [env.n, env.sp, env.sig].map((v) => JSON.stringify(v ?? ''));
  return new Function(`${data.output}\nreturn process(${args.join(',')});`)();
};

const bridge = globalThis.webkit?.messageHandlers?.ytFetch;

// Forwards every request to native URLSession (no CORS, no forbidden-header stripping).
async function bridgeFetch(input, init = {}) {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  const method = init.method ?? (input instanceof Request ? input.method : 'GET');
  const headers = {};
  new Headers(init.headers ?? (input instanceof Request ? input.headers : undefined)).forEach((v, k) => { headers[k] = v; });
  const rawBody = init.body ?? (input instanceof Request && method !== 'GET' ? await input.arrayBuffer() : undefined);
  const body = rawBody == null ? null : toBase64(new Uint8Array(await new Response(rawBody).arrayBuffer()));
  const res = await bridge.postMessage({ url, method, headers, body });
  const bytes = fromBase64(res.body ?? '');
  const nullBody = [101, 204, 205, 304].includes(res.status);
  return new Response(nullBody ? null : bytes, { status: res.status, headers: res.headers });
}

function toBase64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

function fromBase64(b64) {
  const s = atob(b64);
  const bytes = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i);
  return bytes;
}

let clientPromise;
function client() {
  clientPromise ??= Innertube.create({
    retrieve_player: true,
    ...(bridge ? { fetch: bridgeFetch } : {}),
  }).catch((e) => { clientPromise = undefined; throw e; });
  return clientPromise;
}

// googlevideo cuts adaptive formats off after about a minute of media unless the URL carries a
// GVS PO token it trusts. Set false to play only the muxed stream (itag 18, 360p).
const ADAPTIVE_STREAMS = true;

// GVS PO tokens (BotGuard, as YouTube's web player does). Without one, googlevideo serves only
// about the first minute of an adaptive format. The minter lives as long as its integrity token.
let minterState;
async function poMinter(yt) {
  if (minterState && Date.now() < minterState.expiresAt) return minterState.minter;
  const doFetch = bridge ? bridgeFetch : fetch;
  // BotGuard reads yt.config_.EVENT_ID; without a real server-issued one the minted tokens are
  // untrusted (status 3 / 403 past ~60 s). Any youtube.com page's ytcfg carries one.
  // All minter requests carry node fetch's UA: it was the only one that minted trusted tokens
  // (URLSession's UA gets m.youtube.com, refused; browser UAs mint untrusted 124-char tokens).
  const ua = { 'User-Agent': 'node' };
  const page = await (await doFetch('https://www.youtube.com/', { headers: { 'Accept-Language': 'en-US', ...ua } })).text();
  const eventId = page.match(/"EVENT_ID":"([^"]+)"/)?.[1];
  if (!eventId) throw new Error('No EVENT_ID in the youtube.com ytcfg');
  globalThis.yt = { config_: { EVENT_ID: eventId } };
  // The challenge must come from the same page as the EVENT_ID (an /att/get one mints untrusted tokens).
  const att = page.match(/window\.ytAtN\(\s*({[\s\S]*?})\s*\)/)?.[1];
  const raw = att ? parseLooseJSON(att).R?.bgChallenge : null;
  if (!raw) throw new Error('No BotGuard challenge in the youtube.com page');
  const challenge = { program: raw.program, global_name: raw.globalName, interpreter_url: { private_do_not_access_or_else_trusted_resource_url_wrapped_value: raw.interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue } };
  const interpreterUrl = challenge.interpreter_url.private_do_not_access_or_else_trusted_resource_url_wrapped_value;
  new Function(await (await doFetch(`https:${interpreterUrl}`, { headers: ua })).text())();
  const botguard = await BotGuardClient.create({ program: challenge.program, globalName: challenge.global_name, globalObject: globalThis });
  const webPoSignalOutput = [];
  const botguardResponse = await botguard.snapshot({ webPoSignalOutput });
  const res = await doFetch('https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT', {
    method: 'POST',
    headers: { ...ua, 'content-type': 'application/json+protobuf', 'x-goog-api-key': GOOG_API_KEY, 'x-user-agent': 'grpc-web-javascript/0.1' },
    body: JSON.stringify(['O43z0dpjhgX20SCx4KAo', botguardResponse]),
  });
  const [integrityToken, ttlSecs] = await res.json();
  if (typeof integrityToken !== 'string') throw new Error('BotGuard integrity token was refused');
  const minter = await WebPoMinter.create({ integrityToken }, webPoSignalOutput);
  minterState = { minter, expiresAt: Date.now() + Math.max(60, (ttlSecs ?? 3600) - 300) * 1000 };
  return minter;
}

const thumbs = (list) => (list ?? []).map((t) => ({ url: t.url.startsWith('//') ? `https:${t.url}` : t.url, width: t.width, height: t.height }));
const toInt = (text) => { const n = parseInt(String(text ?? '').replace(/[^0-9]/g, ''), 10); return Number.isNaN(n) ? null : n; };

// ponytail: one cached search for paging; concurrent searches for different queries restart at page 1.
let lastSearch;

async function search(query, page = 1, retried = false) {
  const yt = await client();
  let result;
  if (page > 1 && lastSearch?.query === query && lastSearch.page === page - 1 && lastSearch.result.has_continuation) {
    result = await lastSearch.result.getContinuation();
  } else {
    result = await yt.search(query, { type: 'video' });
    page = 1;
  }
  lastSearch = { query, page, result };
  const videos = result.videos
    .filter((v) => v.type === 'Video' && v.video_id)
    .map((v) => ({
      id: v.video_id,
      title: v.title?.toString() ?? '',
      authorId: v.author?.id ?? '',
      author: v.author?.name ?? '',
      duration: v.duration?.seconds ?? 0,
      viewCount: toInt(v.view_count?.toString()),
      publishedText: v.published?.toString() || null,
      thumbnails: thumbs(v.thumbnails),
      isLive: Boolean(v.is_live),
    }));
  // YouTube occasionally returns an empty page to a session; a fresh session usually fixes it.
  if (!videos.length && page === 1 && !retried) {
    clientPromise = undefined;
    return search(query, 1, true);
  }
  return { videos, hasMore: Boolean(result.has_continuation) };
}

async function video(id) {
  const yt = await client();
  // IOS returns an HLS manifest whose URLs need no PO token or deciphering (AVPlayer-friendly).
  const info = await yt.getBasicInfo(id, { client: 'IOS' });
  const b = info.basic_info;
  if (info.playability_status?.status !== 'OK') {
    throw new Error(info.playability_status?.reason || `Video is ${info.playability_status?.status}`);
  }
  const streams = [];
  // Adaptive (video-only / audio-only) formats from MWEB with a video-bound PO token (IOS URLs
  // still 403 past ~60 s with one). Yattee's MPV player merges the best pair. On any failure the
  // video falls back to the muxed streams below.
  let pot = null;
  let adaptive = [];
  if (ADAPTIVE_STREAMS) {
    try {
      // GenerateIT intermittently refuses a snapshot; one rebuild from a fresh page usually passes.
      pot = await (await poMinter(yt).catch(() => poMinter(yt))).mintAsWebsafeString(id);
      // 124-char tokens are the untrusted shape (minted without a valid EVENT_ID); rebuild next time.
      if (pot.length === 124) { minterState = undefined; throw new Error('untrusted PO token'); }
      const mweb = await yt.getBasicInfo(id, { client: 'MWEB', po_token: pot });
      // Some MWEB responses are SABR-only (formats without a URL); decipher throws and we fall back.
      const formats = mweb.streaming_data?.adaptive_formats ?? [];
      const urls = await Promise.all(formats.map((f) => f.decipher(yt.session.player)));
      adaptive = formats.map((f, i) => [f, urls[i]]);
    } catch (e) {
      console.log(`adaptive streams unavailable for ${id}: ${e?.message ?? e}`);
      adaptive = [];
    }
  }
  for (const [f, deciphered] of adaptive) {
    const isAudio = f.mime_type?.startsWith('audio/');
    const url = new URL(deciphered);
    url.searchParams.set('pot', pot);
    streams.push({
      url: url.href,
      kind: isAudio ? 'audio' : 'video',
      itag: f.itag,
      width: f.width ?? null,
      height: f.height ?? null,
      mimeType: f.mime_type ?? null,
      bitrate: f.bitrate ?? null,
      fps: f.fps ?? null,
      contentLength: f.content_length ?? null,
      qualityLabel: f.quality_label ?? null,
      audioQuality: f.audio_quality ?? null,
      audioSampleRate: f.audio_sample_rate ?? null,
      // Byte ranges of the init segment and sidx (fragmented mp4 only); used for AirPlay HLS.
      initRange: f.init_range ? [f.init_range.start, f.init_range.end] : null,
      indexRange: f.index_range ? [f.index_range.start, f.index_range.end] : null,
      audioTrack: f.audio_track ? { id: f.audio_track.id ?? null, displayName: f.audio_track.display_name ?? null, isDefault: f.audio_track.audio_is_default ?? null } : null,
    });
  }
  // Muxed progressive fallback (itag 18 etc.), deciphered via the player script.
  let muxed = info.streaming_data?.formats ?? [];
  if (!muxed.length && !info.streaming_data?.hls_manifest_url) {
    muxed = (await yt.getBasicInfo(id, { client: 'MWEB' })).streaming_data?.formats ?? [];
  }
  for (const f of muxed) {
    streams.push({
      url: await f.decipher(yt.session.player),
      kind: 'muxed',
      itag: f.itag,
      width: f.width ?? null,
      height: f.height ?? null,
      mimeType: f.mime_type ?? null,
      bitrate: f.bitrate ?? null,
      fps: f.fps ?? null,
      contentLength: f.content_length ?? null,
      qualityLabel: f.quality_label ?? null,
    });
  }
  return {
    id,
    title: b.title ?? '',
    description: b.short_description ?? null,
    authorId: b.channel_id ?? '',
    author: b.author ?? '',
    duration: b.duration ?? 0,
    viewCount: b.view_count ?? null,
    thumbnails: thumbs(b.thumbnail),
    isLive: Boolean(b.is_live),
    hls: info.streaming_data?.hls_manifest_url ?? null,
    streams,
  };
}

// "4.56M subscribers" -> 4560000, "123K" -> 123000, "1,234 views" -> 1234.
const toCount = (text) => {
  const m = String(text ?? '').replace(/,/g, '').match(/([\d.]+)\s*([KMB])?/i);
  if (!m) return null;
  return Math.round(parseFloat(m[1]) * ({ K: 1e3, M: 1e6, B: 1e9 }[m[2]?.toUpperCase()] ?? 1));
};
const toSeconds = (text) => String(text).split(':').reduce((acc, part) => acc * 60 + Number(part), 0);

// ponytail: one channel object cached (channel() and channelVideos() run back to back for the same id).
let lastChannel;
function getChannel(id) {
  if (lastChannel?.id !== id) {
    lastChannel = { id, promise: client().then((yt) => yt.getChannel(id)) };
    lastChannel.promise.catch(() => { lastChannel = undefined; });
  }
  return lastChannel.promise;
}

// Continuation feeds live here; Swift only sees the opaque token.
const continuations = new Map();
let nextToken = 0;
function storeContinuation(feed) {
  if (!feed.has_continuation) return null;
  const token = `c${nextToken++}`;
  continuations.set(token, feed);
  if (continuations.size > 50) continuations.delete(continuations.keys().next().value);
  return token;
}
async function page(id, token, load) {
  if (!token) return load(await getChannel(id));
  const feed = continuations.get(token);
  if (!feed) throw new Error('This page expired; reload the channel');
  return feed.getContinuation();
}

async function channel(id) {
  const ch = await getChannel(id);
  const m = ch.metadata;
  const parts = (ch.header?.content?.metadata?.metadata_rows ?? []).flatMap((r) => r.metadata_parts ?? []).map((p) => p.text?.toString() ?? '');
  return {
    id: m.external_id || id,
    name: m.title ?? '',
    description: m.description || null,
    subscriberCount: toCount(parts.find((t) => /subscriber/i.test(t))),
    videoCount: toCount(parts.find((t) => /video/i.test(t))),
    avatar: thumbs(m.avatar)[0]?.url ?? null,
    banner: thumbs(ch.header?.content?.banner?.image)[0]?.url ?? null,
  };
}

function lockupVideo(item, ch) {
  if (item.type === 'ShortsLockupView') {
    const id = item.on_tap_endpoint?.payload?.videoId;
    return id && {
      id, title: item.overlay_metadata?.primary_text?.toString() || item.accessibility_text?.split(',')[0] || '',
      authorId: ch.id, author: ch.name, duration: 0,
      viewCount: toCount(item.overlay_metadata?.secondary_text?.toString()),
      publishedText: null, thumbnails: thumbs(item.thumbnail_view_model?.image), isLive: false,
    };
  }
  if (item.type !== 'LockupView' || item.content_type !== 'VIDEO') return null;
  const badges = (item.content_image?.overlays ?? []).flatMap((o) => o.badges ?? []).map((b) => b.text ?? '');
  const durationText = badges.find((t) => /^\d+(:\d+)+$/.test(t));
  const parts = (item.metadata?.metadata?.metadata_rows ?? []).flatMap((r) => r.metadata_parts ?? []).map((p) => p.text?.toString() ?? '');
  return {
    id: item.content_id,
    title: item.metadata?.title?.toString() ?? '',
    authorId: ch.id, author: ch.name,
    duration: durationText ? toSeconds(durationText) : 0,
    viewCount: toCount(parts[0]),
    publishedText: parts[1] || null,
    thumbnails: thumbs(item.content_image?.image),
    isLive: badges.some((t) => /live/i.test(t)),
  };
}

async function channelVideos(id, token, load) {
  const feed = await page(id, token, load);
  const ch = (await getChannel(id).catch(() => null))?.metadata ?? {};
  const owner = { id, name: ch.title ?? '' };
  const videos = (feed.videos ?? []).map((v) => lockupVideo(v, owner)).filter(Boolean);
  return { videos, continuation: storeContinuation(feed) };
}

async function channelPlaylists(id, token) {
  const feed = await page(id, token, (ch) => ch.getPlaylists());
  const playlists = (feed.playlists ?? [])
    .filter((p) => p.type === 'LockupView' && p.content_id)
    .map((p) => {
      const img = p.content_image?.primary_thumbnail;
      const badge = (img?.overlays ?? []).flatMap((o) => o.badges ?? []).map((b) => b.text ?? '').find((t) => /video/i.test(t));
      return { id: p.content_id, title: p.metadata?.title?.toString() ?? '', videoCount: toCount(badge) ?? 0, thumbnail: thumbs(img?.image)[0]?.url ?? null };
    });
  return { playlists, continuation: storeContinuation(feed) };
}

async function playlist(id) {
  const yt = await client();
  const pl = await yt.getPlaylist(id);
  const owner = { id: pl.info.author?.id ?? '', name: pl.info.author?.name ?? '' };
  const videos = pl.items
    .filter((v) => (v.type === 'PlaylistVideo' && v.id) || v.type === 'LockupView')
    .map((v) => v.type === 'LockupView' ? lockupVideo(v, owner) : ({
      id: v.id,
      title: v.title?.toString() ?? '',
      authorId: v.author?.id ?? '',
      author: v.author?.name ?? '',
      duration: v.duration?.seconds ?? 0,
      viewCount: null,
      publishedText: null,
      thumbnails: thumbs(v.thumbnails),
      isLive: Boolean(v.is_live),
    }))
    .filter(Boolean);
  return {
    id,
    title: pl.info.title ?? '',
    description: pl.info.description || null,
    authorId: owner.id,
    author: owner.name,
    videoCount: toCount(pl.info.total_items) ?? videos.length,
    thumbnail: thumbs(pl.info.thumbnails)[0]?.url ?? videos[0]?.thumbnails[0]?.url ?? null,
    videos,
  };
}

const json = (fn) => async (...args) => JSON.stringify(await fn(...args));
globalThis.YT = {
  search: json(search),
  video: json(video),
  channel: json(channel),
  channelVideos: json((id, token) => channelVideos(id, token, (ch) => ch.getVideos())),
  channelShorts: json((id, token) => channelVideos(id, token, (ch) => ch.getShorts())),
  channelStreams: json((id, token) => channelVideos(id, token, (ch) => ch.getLiveStreams())),
  channelPlaylists: json(channelPlaylists),
  playlist: json(playlist),
};
