#!/usr/bin/env node

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { mkdir, readFile, writeFile, access } from 'node:fs/promises';

const execFileAsync = promisify(execFile);
const MAX_BUFFER = 100 * 1024 * 1024;

function parseArgs(argv) {
  const args = {
    manifest: '',
    output: '',
    concurrency: 4,
    limit: 0,
    force: false,
    resourceIds: [],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const current = argv[index];
    if (current === '--manifest') {
      args.manifest = argv[index + 1] || '';
      index += 1;
      continue;
    }
    if (current === '--output') {
      args.output = argv[index + 1] || '';
      index += 1;
      continue;
    }
    if (current === '--concurrency') {
      args.concurrency = Number(argv[index + 1] || 4);
      index += 1;
      continue;
    }
    if (current === '--limit') {
      args.limit = Number(argv[index + 1] || 0);
      index += 1;
      continue;
    }
    if (current === '--force') {
      args.force = true;
      continue;
    }
    if (current === '--resource-ids') {
      args.resourceIds = String(argv[index + 1] || '')
        .split(',')
        .map((item) => item.trim())
        .filter(Boolean);
      index += 1;
      continue;
    }
    if (current === '--help' || current === '-h') {
      printUsage();
      process.exit(0);
    }
    throw new Error(`Unknown argument: ${current}`);
  }

  if (!args.manifest || !args.output) {
    printUsage();
    throw new Error('Both --manifest and --output are required.');
  }

  if (!Number.isFinite(args.concurrency) || args.concurrency < 1) {
    throw new Error('--concurrency must be a positive number.');
  }

  if (!Number.isFinite(args.limit) || args.limit < 0) {
    throw new Error('--limit must be zero or a positive number.');
  }

  return args;
}

function printUsage() {
  console.log(`Usage:
  node scripts/export_cooper_knowledge.mjs \\
    --manifest /path/to/tree.json \\
    --output /path/to/export-dir \\
    [--concurrency 4] [--limit 0] [--force] [--resource-ids 123,456]`);
}

function sanitizeName(input, fallback) {
  const normalized = (input || '')
    .replace(/[\\/:*?"<>|]/g, '_')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/[. ]+$/g, '');
  return normalized || fallback;
}

function ensureUniqueName(baseName, usedNames) {
  if (!usedNames.has(baseName)) {
    usedNames.add(baseName);
    return baseName;
  }
  let index = 2;
  while (usedNames.has(`${baseName} (${index})`)) {
    index += 1;
  }
  const uniqueName = `${baseName} (${index})`;
  usedNames.add(uniqueName);
  return uniqueName;
}

function parseKnowledgeHref(href) {
  const match = href.match(/\/knowledge\/(\d+)\/(\d+)(?:\/|$)/);
  if (!match) {
    throw new Error(`Unsupported Cooper knowledge link: ${href}`);
  }
  return {
    knowledgeId: match[1],
    resourceId: match[2],
  };
}

function buildDocEntries(treeItems) {
  const folderState = [];
  const folderNamesByParent = new Map();
  const docNamesByParent = new Map();
  const docs = [];

  for (const item of treeItems) {
    if (!item || !item.kind || !item.href) {
      continue;
    }

    if (item.kind === 'folder') {
      const parentKey = folderState.slice(0, item.depth).map((entry) => entry.uniqueName).join('/');
      const usedFolders = folderNamesByParent.get(parentKey) || new Set();
      folderNamesByParent.set(parentKey, usedFolders);
      const uniqueName = ensureUniqueName(
        sanitizeName(item.text, `folder-${item.depth}`),
        usedFolders,
      );

      folderState[item.depth] = {
        rawName: item.text,
        uniqueName,
      };
      folderState.length = item.depth + 1;
      continue;
    }

    if (item.kind !== 'doc') {
      continue;
    }

    const parentSegments = folderState.slice(0, item.depth);
    const parentKey = parentSegments.map((entry) => entry.uniqueName).join('/');
    const usedDocs = docNamesByParent.get(parentKey) || new Set();
    docNamesByParent.set(parentKey, usedDocs);

    const uniqueBaseName = ensureUniqueName(
      sanitizeName(item.text, `doc-${docs.length + 1}`),
      usedDocs,
    );
    const ids = parseKnowledgeHref(item.href);

    docs.push({
      title: item.text,
      href: item.href,
      depth: item.depth,
      knowledgeId: ids.knowledgeId,
      resourceId: ids.resourceId,
      relativeDir: path.join(...parentSegments.map((entry) => entry.uniqueName)),
      rawFolderTrail: parentSegments.map((entry) => entry.rawName),
      uniqueBaseName,
    });
  }

  return docs;
}

async function pathExists(targetPath) {
  try {
    await access(targetPath);
    return true;
  } catch {
    return false;
  }
}

async function readManifest(manifestPath) {
  const text = await readFile(manifestPath, 'utf8');
  const parsed = JSON.parse(text);
  if (!Array.isArray(parsed)) {
    throw new Error('Manifest must be a JSON array exported from the tree capture.');
  }
  return parsed;
}

function formatFrontmatterValue(value) {
  return JSON.stringify(String(value ?? ''));
}

async function readDocContent(resourceId, appId) {
  const { stdout } = await execFileAsync(
    'mcporter',
    ['call', 'Cooper.readContent', `resourceId=${resourceId}`, `appId=${appId}`, '--output', 'json'],
    { maxBuffer: MAX_BUFFER },
  );
  const trimmed = stdout.trim();
  try {
    return JSON.parse(trimmed);
  } catch {
    return decodeLooseQuotedString(trimmed);
  }
}

function decodeLooseQuotedString(rawText) {
  let text = rawText.trim();
  if (text.startsWith('"') && text.endsWith('"')) {
    text = text.slice(1, -1);
  }

  let output = '';
  for (let index = 0; index < text.length; index += 1) {
    const current = text[index];
    if (current !== '\\') {
      output += current;
      continue;
    }

    const next = text[index + 1];
    if (next === undefined) {
      output += '\\';
      break;
    }

    if (next === 'n') {
      output += '\n';
      index += 1;
      continue;
    }
    if (next === 'r') {
      output += '\r';
      index += 1;
      continue;
    }
    if (next === 't') {
      output += '\t';
      index += 1;
      continue;
    }
    if (next === 'b') {
      output += '\b';
      index += 1;
      continue;
    }
    if (next === 'f') {
      output += '\f';
      index += 1;
      continue;
    }
    if (next === '"' || next === '\\' || next === '/') {
      output += next;
      index += 1;
      continue;
    }
    if (next === 'u' && /^[0-9a-fA-F]{4}$/.test(text.slice(index + 2, index + 6))) {
      output += String.fromCharCode(parseInt(text.slice(index + 2, index + 6), 16));
      index += 5;
      continue;
    }

    output += next;
    index += 1;
  }

  return output;
}

function collectDiagramBlocks(content) {
  const matches = [];
  const regex = /```(flowchart|mindmap)\s*([\s\S]*?)```/g;
  let match;
  while ((match = regex.exec(content)) !== null) {
    const rawJson = match[2].trim();
    try {
      const payload = JSON.parse(rawJson);
      if (payload?.fileUrl) {
        matches.push({
          diagramType: match[1],
          rawBlock: match[0],
          url: payload.fileUrl,
        });
      }
    } catch {
      // Ignore malformed blocks and keep the source untouched.
    }
  }
  return matches;
}

function collectMarkdownImages(content) {
  const matches = [];
  let cursor = 0;

  while (cursor < content.length) {
    const imageStart = content.indexOf('![', cursor);
    if (imageStart === -1) {
      break;
    }

    const altEnd = content.indexOf('](', imageStart + 2);
    if (altEnd === -1) {
      break;
    }

    let urlCursor = altEnd + 2;
    let depth = 1;
    while (urlCursor < content.length && depth > 0) {
      const current = content[urlCursor];
      if (current === '(') {
        depth += 1;
      } else if (current === ')') {
        depth -= 1;
      }
      urlCursor += 1;
    }

    if (depth !== 0) {
      break;
    }

    const alt = content.slice(imageStart + 2, altEnd);
    const url = content.slice(altEnd + 2, urlCursor - 1).trim();
    if (/^https?:\/\//.test(url)) {
      matches.push({ alt, url });
    }

    cursor = urlCursor;
  }
  return matches;
}

function collectHtmlImages(content) {
  const matches = [];
  const regex = /<img\b[^>]*\bsrc="(https?:\/\/[^"]+)"[^>]*>/g;
  let match;
  while ((match = regex.exec(content)) !== null) {
    matches.push({
      url: match[1],
    });
  }
  return matches;
}

function extFromContentType(contentType) {
  const normalized = (contentType || '').split(';')[0].trim().toLowerCase();
  const mapping = new Map([
    ['image/png', '.png'],
    ['image/jpeg', '.jpg'],
    ['image/jpg', '.jpg'],
    ['image/webp', '.webp'],
    ['image/gif', '.gif'],
    ['image/svg+xml', '.svg'],
    ['application/json', '.json'],
    ['text/plain', '.txt'],
    ['text/html', '.html'],
  ]);
  return mapping.get(normalized) || '';
}

function extFromUrl(rawUrl) {
  try {
    const pathname = new URL(rawUrl).pathname;
    const ext = path.extname(pathname);
    return ext ? ext.toLowerCase() : '';
  } catch {
    return '';
  }
}

async function materializeAssets(content, markdownFilePath, force) {
  const assetDirName = `${path.basename(markdownFilePath, path.extname(markdownFilePath))}.assets`;
  const assetDirPath = path.join(path.dirname(markdownFilePath), assetDirName);

  const imageUrls = new Set();
  const diagramBlocks = collectDiagramBlocks(content);
  const diagramUrls = new Set();

  for (const item of collectMarkdownImages(content)) {
    imageUrls.add(item.url);
  }
  for (const item of collectHtmlImages(content)) {
    imageUrls.add(item.url);
  }
  for (const item of diagramBlocks) {
    diagramUrls.add(item.url);
  }

  if (imageUrls.size === 0 && diagramUrls.size === 0) {
    return { content, assets: [] };
  }

  await mkdir(assetDirPath, { recursive: true });

  let imageIndex = 0;
  let diagramIndex = 0;
  let updatedContent = content;
  const assets = [];

  const urlToRelativePath = new Map();

  for (const [type, urls] of [['image', imageUrls], ['diagram', diagramUrls]]) {
    for (const url of urls) {
      if (type === 'diagram') {
        diagramIndex += 1;
      } else {
        imageIndex += 1;
      }
      const fileStem = type === 'diagram'
        ? `diagram-${String(diagramIndex).padStart(3, '0')}`
        : `image-${String(imageIndex).padStart(3, '0')}`;

      const tmpExt = extFromUrl(url) || (type === 'diagram' ? '.svg' : '');
      let fileName = `${fileStem}${tmpExt}`;
      let assetPath = path.join(assetDirPath, fileName);

      if (force || !(await pathExists(assetPath))) {
        const response = await fetch(url);
        if (!response.ok) {
          throw new Error(`Asset download failed (${response.status}) for ${url}`);
        }
        const contentType = response.headers.get('content-type') || '';
        const betterExt = extFromUrl(url) || extFromContentType(contentType) || '.bin';
        fileName = `${fileStem}${betterExt}`;
        assetPath = path.join(assetDirPath, fileName);
        const buffer = Buffer.from(await response.arrayBuffer());
        await writeFile(assetPath, buffer);
        assets.push({
          url,
          relativePath: path.posix.join(assetDirName, fileName),
          bytes: buffer.byteLength,
          contentType,
        });
      } else {
        assets.push({
          url,
          relativePath: path.posix.join(assetDirName, fileName),
          bytes: null,
          contentType: null,
        });
      }

      urlToRelativePath.set(url, path.posix.join(assetDirName, fileName));
    }
  }

  for (const item of diagramBlocks) {
    const relativePath = urlToRelativePath.get(item.url);
    if (relativePath) {
      updatedContent = updatedContent.replace(item.rawBlock, `![${item.diagramType}](${relativePath})`);
    }
  }

  for (const [url, relativePath] of urlToRelativePath.entries()) {
    updatedContent = updatedContent.split(url).join(relativePath);
  }

  return { content: updatedContent, assets };
}

async function exportDoc(doc, outputRoot, force) {
  const targetDir = path.join(outputRoot, doc.relativeDir);
  await mkdir(targetDir, { recursive: true });

  const markdownPath = path.join(targetDir, `${doc.uniqueBaseName}.md`);
  if (!force && (await pathExists(markdownPath))) {
    return {
      status: 'skipped',
      markdownPath,
      title: doc.title,
      resourceId: doc.resourceId,
      href: doc.href,
      assets: [],
    };
  }

  const rawContent = await readDocContent(doc.resourceId, 4);
  const assetResult = await materializeAssets(rawContent, markdownPath, force);

  const frontmatter = [
    '---',
    `title: ${formatFrontmatterValue(doc.title)}`,
    `source: ${formatFrontmatterValue(doc.href)}`,
    `knowledgeId: ${formatFrontmatterValue(doc.knowledgeId)}`,
    `resourceId: ${formatFrontmatterValue(doc.resourceId)}`,
    `exportedAt: ${formatFrontmatterValue(new Date().toISOString())}`,
    '---',
    '',
  ].join('\n');

  await writeFile(markdownPath, `${frontmatter}${assetResult.content.trim()}\n`, 'utf8');

  return {
    status: 'exported',
    markdownPath,
    title: doc.title,
    resourceId: doc.resourceId,
    href: doc.href,
    assets: assetResult.assets,
  };
}

async function runWithConcurrency(items, concurrency, worker) {
  const results = [];
  let cursor = 0;

  const runners = Array.from({ length: concurrency }, async () => {
    while (cursor < items.length) {
      const currentIndex = cursor;
      cursor += 1;
      results[currentIndex] = await worker(items[currentIndex], currentIndex);
    }
  });

  await Promise.all(runners);
  return results;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const manifestPath = path.resolve(args.manifest);
  const outputRoot = path.resolve(args.output);

  const treeItems = await readManifest(manifestPath);
  const docs = buildDocEntries(treeItems);
  const filteredDocs = args.resourceIds.length > 0
    ? docs.filter((doc) => args.resourceIds.includes(doc.resourceId))
    : docs;
  const exportDocs = args.limit > 0 ? filteredDocs.slice(0, args.limit) : filteredDocs;

  await mkdir(outputRoot, { recursive: true });

  console.log(`Preparing to export ${exportDocs.length} documents to ${outputRoot}`);

  let completed = 0;
  const startedAt = Date.now();
  const results = await runWithConcurrency(exportDocs, args.concurrency, async (doc, index) => {
    const label = `[${index + 1}/${exportDocs.length}] ${doc.title}`;
    try {
      const result = await exportDoc(doc, outputRoot, args.force);
      completed += 1;
      console.log(`${label} -> ${result.status}`);
      return result;
    } catch (error) {
      completed += 1;
      console.error(`${label} -> failed: ${error.message}`);
      return {
        status: 'failed',
        title: doc.title,
        resourceId: doc.resourceId,
        href: doc.href,
        error: error.message,
      };
    }
  });

  const summary = {
    generatedAt: new Date().toISOString(),
    elapsedSeconds: Number(((Date.now() - startedAt) / 1000).toFixed(1)),
    totalDocs: exportDocs.length,
    exported: results.filter((item) => item.status === 'exported').length,
    skipped: results.filter((item) => item.status === 'skipped').length,
    failed: results.filter((item) => item.status === 'failed').length,
    results,
  };

  const summaryPath = path.join(outputRoot, 'export-summary.json');
  await writeFile(summaryPath, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');

  console.log(`Summary written to ${summaryPath}`);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
