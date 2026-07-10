// Copies the ethers UMD bundle from node_modules into frontend/vendor/ so the
// frontend stays a zero-build static page without committing a 500KB minified
// file to git. Run automatically via `npm install` (postinstall).
const fs = require("fs");
const path = require("path");

const src = path.join(__dirname, "..", "node_modules", "ethers", "dist", "ethers.umd.min.js");
const destDir = path.join(__dirname, "..", "frontend", "vendor");
fs.mkdirSync(destDir, { recursive: true });
fs.copyFileSync(src, path.join(destDir, "ethers.umd.min.js"));
console.log("vendored ethers ->", path.join(destDir, "ethers.umd.min.js"));
