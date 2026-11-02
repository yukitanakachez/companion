import { liveContentDeps } from "./content-deps";
import { startDriveScript } from "./drive";

startDriveScript({ ...liveContentDeps(), isTopFrame: window === window.top });
