import { promises as fs } from "fs";
import path from "path";

// Note: Install puppeteer first: npm install --save-dev puppeteer
// Or use: npm install --save-dev puppeteer-core
let puppeteer: any;
try {
  puppeteer = require("puppeteer");
} catch {
  console.error("Error: puppeteer is not installed.");
  console.error("Please install it with: npm install --save-dev puppeteer");
  process.exit(1);
}

interface ChartExport {
  htmlFile: string;
  outputDir: string;
  outputName: string;
  selectors: string[];
  descriptions: string[];
}

async function exportChart(
  htmlPath: string,
  outputPath: string,
  selector: string,
  description: string
): Promise<void> {
  console.log(`Exporting ${description}...`);
  
  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });
  
  try {
    const page = await browser.newPage();
    
    // Set viewport for consistent sizing
    await page.setViewport({ width: 1600, height: 900 });
    
    await page.goto(`file://${htmlPath}`, {
      waitUntil: 'networkidle0',
      timeout: 30000
    });
    
    // Wait for charts to render
    await page.waitForSelector(selector, { timeout: 15000 });
    
    // Wait for Chart.js to finish rendering
    await page.waitForFunction(
      (sel: string) => {
        const canvas = document.querySelector(sel);
        return canvas && (canvas as HTMLCanvasElement).getContext('2d');
      },
      { timeout: 10000 },
      selector
    );
    
    await page.waitForTimeout(3000); // Additional wait for Chart.js animations
    
    const element = await page.$(selector);
    if (!element) {
      throw new Error(`Element not found: ${selector}`);
    }
    
    await element.screenshot({
      path: outputPath,
      type: 'png',
      fullPage: false
    });
    
    console.log(`  ✓ Saved to ${outputPath}`);
  } catch (error) {
    console.error(`  ✗ Error exporting ${description}:`, error);
    throw error;
  } finally {
    await browser.close();
  }
}

async function findChartSelectors(htmlPath: string): Promise<string[]> {
  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });
  
  try {
    const page = await browser.newPage();
    await page.goto(`file://${htmlPath}`, {
      waitUntil: 'networkidle0',
      timeout: 30000
    });
    
    // Find all chart canvas elements
    const selectors = await page.evaluate(() => {
      const charts: string[] = [];
      const canvases = document.querySelectorAll('canvas');
      canvases.forEach((canvas, index) => {
        const id = canvas.id || `chart-${index}`;
        charts.push(`#${id}`);
      });
      return charts;
    });
    
    return selectors;
  } finally {
    await browser.close();
  }
}

async function main() {
  console.log("=== Exporting Visualizations ===\n");
  
  const projectRoot = process.cwd();
  const docsDir = path.join(projectRoot, "docs");
  const imagesDir = path.join(docsDir, "images");
  
  // Create images directory if it doesn't exist
  await fs.mkdir(imagesDir, { recursive: true });
  
  const exports = [
    {
      htmlFile: path.join(projectRoot, "gas-bound-visualization.html"),
      outputDir: imagesDir,
      outputName: "gas-bound",
    },
    {
      htmlFile: path.join(projectRoot, "gap-analysis-visualization.html"),
      outputDir: imagesDir,
      outputName: "gap-analysis",
    }
  ];
  
  for (const exportConfig of exports) {
    const htmlPath = path.resolve(exportConfig.htmlFile);
    
    // Check if HTML file exists
    try {
      await fs.access(htmlPath);
    } catch {
      console.warn(`⚠️  HTML file not found: ${htmlPath}`);
      console.warn(`   Skipping ${exportConfig.outputName} exports\n`);
      continue;
    }
    
    console.log(`\nProcessing ${exportConfig.outputName}...`);
    
    // Dynamically find all charts
    const selectors = await findChartSelectors(htmlPath);
    console.log(`  Found ${selectors.length} charts`);
    
    for (let i = 0; i < selectors.length; i++) {
      const selector = selectors[i];
      const isComparison = selector.includes('comparison');
      const outputName = isComparison
        ? `${exportConfig.outputName}-comparison.png`
        : `${exportConfig.outputName}-chart-${i - (isComparison ? 0 : 1)}.png`;
      const outputPath = path.join(exportConfig.outputDir, outputName);
      
      const description = isComparison
        ? `Comparison Chart - ${exportConfig.outputName}`
        : `Chart ${i} - ${exportConfig.outputName}`;
      
      try {
        await exportChart(htmlPath, outputPath, selector, description);
      } catch (error) {
        console.error(`  ✗ Failed to export ${description}:`, error);
      }
    }
  }
  
  console.log("\n✓ Export complete!");
  console.log(`\nImages saved to: ${imagesDir}`);
  console.log("\nTo embed in markdown, use:");
  console.log('  ![Description](./images/filename.png)');
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
