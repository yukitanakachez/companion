import { liveContentDeps } from "../content-deps";
import { replaceInstance } from "../single-instance";
import { YouTubeController } from "./controller";
import { requestPlayerData } from "./player-data";
import { loadTranscript, openPanelAndScrape } from "./transcript";

replaceInstance(window, "youtube", () => {
  const controller = new YouTubeController({
    ...liveContentDeps(),
    requestPlayerData: (videoId) => requestPlayerData(window, videoId),
    loadTranscript: (track) => loadTranscript(track, { fetch: window.fetch.bind(window), openPanelAndScrape: () => openPanelAndScrape(document) }),
  });
  void controller.start();
  return () => controller.stop();
});
