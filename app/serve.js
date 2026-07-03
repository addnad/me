"use strict";

// Zero-dependency static server for local development:  node serve.js
// (The packaged app runs under the Pear runtime instead: `pear run .`)

const http = require("http");
const fs = require("fs");
const path = require("path");

const TYPES = {
  ".html": "text/html",
  ".css": "text/css",
  ".js": "text/javascript",
  ".svg": "image/svg+xml",
  ".json": "application/json",
};

const PORT = process.env.PORT || 8080;

http
  .createServer((req, res) => {
    const url = req.url === "/" ? "/index.html" : req.url.split("?")[0];
    const file = path.join(__dirname, path.normalize(url));
    if (!file.startsWith(__dirname) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      res.writeHead(404);
      return res.end("not found");
    }
    res.writeHead(200, { "Content-Type": TYPES[path.extname(file)] || "application/octet-stream" });
    fs.createReadStream(file).pipe(res);
  })
  .listen(PORT, () => console.log(`sideline app → http://localhost:${PORT}`));
