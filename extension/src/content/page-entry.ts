import { liveContentDeps } from "./content-deps";
import { startPageScript } from "./page";
import { replaceInstance } from "./single-instance";

replaceInstance(window, "page", () => startPageScript(liveContentDeps()));
