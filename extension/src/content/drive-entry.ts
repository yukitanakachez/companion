import type { BackgroundToContent } from "../shared/messages";
import { liveContentDeps } from "./content-deps";
import { startDriveScript } from "./drive";
import { handleViewerMessage } from "./drive-viewer";
import { replaceInstance } from "./single-instance";

const isTopFrame = window === window.top;
replaceInstance(window, "drive", () => startDriveScript({ ...liveContentDeps(), isTopFrame }));

if (isTopFrame) {
  chrome.runtime.onMessage.addListener((msg: BackgroundToContent, _sender, reply) => {
    if (msg.kind !== "viewer") return false;
    void handleViewerMessage(msg, document).then(reply);
    return true;
  });
}
