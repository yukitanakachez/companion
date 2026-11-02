import type { DriveViewerContext } from "../../../contracts/ts/protocol";
import { driveFileIdFromUrl } from "./classroom";
import type { ContentDeps } from "./content-deps";
import { watchNavigation } from "./navigation";

export function driveViewerContext(url: string, docTitle: string): DriveViewerContext | null {
  const fileId = driveFileIdFromUrl(url);
  if (!fileId) return null;
  const title = docTitle.replace(/ - Google Drive$/, "");
  return { file: { fileId, title, mimeType: /\.pdf$/i.test(title) ? "application/pdf" : null } };
}

/** In a subframe, sends { drive: null } on pagehide. */
export function startDriveScript(deps: ContentDeps & { isTopFrame: boolean }): () => void {
  const { doc, win } = deps;
  let sentFile = false;
  let stopped = false;
  const sendPart = (drive: DriveViewerContext | null) =>
    deps.send({ kind: "contextPart", pageUrl: doc.location.href, pageTitle: doc.title, capturedAtMs: deps.now(), part: { drive } });
  const push = async () => {
    const url = doc.location.href;
    if (await deps.askBlocked(url)) return;
    if (stopped) return;
    const drive = driveViewerContext(url, doc.title);
    if (drive || sentFile) sendPart(drive);
    sentFile = drive !== null;
  };
  const onPageHide = () => {
    if (!sentFile) return;
    sentFile = false;
    sendPart(null);
  };
  const fire = () => void push();
  fire();
  const stopNav = watchNavigation(win, fire);
  deps.onExtractNow(fire);
  if (!deps.isTopFrame) win.addEventListener("pagehide", onPageHide);
  return () => {
    stopped = true;
    stopNav();
    win.removeEventListener("pagehide", onPageHide);
  };
}
