import { liveContentDeps } from "../content-deps";
import { YouTubeController } from "./controller";
import { requestPlayerData } from "./player-data";
import { loadTranscript, openPanelAndScrape } from "./transcript";

void new YouTubeController({
  ...liveContentDeps(),
  requestPlayerData: (videoId) => requestPlayerData(window, videoId),
  loadTranscript: (track) => loadTranscript(track, { fetch: window.fetch.bind(window), openPanelAndScrape: () => openPanelAndScrape(document) }),
}).start();
