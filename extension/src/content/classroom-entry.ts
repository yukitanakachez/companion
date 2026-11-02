import { startClassroomScript } from "./classroom";
import { liveContentDeps } from "./content-deps";
import { replaceInstance } from "./single-instance";

replaceInstance(window, "classroom", () => startClassroomScript(liveContentDeps()));
