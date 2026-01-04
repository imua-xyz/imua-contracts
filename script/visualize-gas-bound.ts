import { promises as fs } from "fs";
import path from "path";

interface GasBoundData {
  nonce: number;
  txHash: string;
  gasUsed: number;
}

function parseCSV(csvContent: string): GasBoundData[] {
  const lines = csvContent.trim().split("\n");
  if (lines.length < 2) return [];
  
  const headers = lines[0].split(",");
  const records: GasBoundData[] = [];
  
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    
    const values = line.split(",");
    const record: any = {};
    
    for (let j = 0; j < headers.length; j++) {
      const header = headers[j];
      const value = values[j] || "";
      
      // Convert numeric columns
      if (header === "nonce" || header === "gasUsed") {
        const num = parseInt(value, 10);
        record[header] = isNaN(num) ? undefined : num;
      } else {
        record[header] = value;
      }
    }
    
    records.push(record as GasBoundData);
  }
  
  return records;
}

async function main() {
  console.log("=== Gas Bound Results Visualization Generator ===\n");

  // Read CSV file
  const csvPath = path.resolve(process.cwd(), "gas-bound-results.csv");
  console.log(`Reading CSV from ${csvPath}...`);
  
  const csvContent = await fs.readFile(csvPath, "utf-8");
  const records = parseCSV(csvContent);

  console.log(`Loaded ${records.length} records`);

  // Sort by nonce (chronological order)
  records.sort((a, b) => a.nonce - b.nonce);

  // Prepare data for Chart.js
  const chartData = records.map((record, index) => ({
    x: index + 1, // Sequence number starting from 1
    y: record.gasUsed,
    nonce: record.nonce,
    txHash: record.txHash,
  }));

  // Calculate statistics
  const gasValues = records.map(r => r.gasUsed);
  const minGas = Math.min(...gasValues);
  const maxGas = Math.max(...gasValues);
  const avgGas = Math.round(gasValues.reduce((sum, g) => sum + g, 0) / gasValues.length);
  
  // Calculate percentiles
  const sortedGas = [...gasValues].sort((a, b) => a - b);
  const p50 = sortedGas[Math.floor(sortedGas.length * 0.5)];
  const p95 = sortedGas[Math.floor(sortedGas.length * 0.95)];
  const p99 = sortedGas[Math.floor(sortedGas.length * 0.99)];

  console.log(`\nStatistics:`);
  console.log(`  Total Messages: ${records.length}`);
  console.log(`  Min Gas: ${minGas.toLocaleString()}`);
  console.log(`  Max Gas: ${maxGas.toLocaleString()}`);
  console.log(`  Avg Gas: ${avgGas.toLocaleString()}`);
  console.log(`  P50 (Median): ${p50.toLocaleString()}`);
  console.log(`  P95: ${p95.toLocaleString()}`);
  console.log(`  P99: ${p99.toLocaleString()}`);

  // Calculate Y-axis range with padding
  const yPadding = (maxGas - minGas) * 0.1;
  const yMin = Math.max(0, minGas - yPadding);
  const yMax = maxGas + yPadding;

  // Generate HTML
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Gas Usage Over Time - Delegation Gas Bound Test</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background-color: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 {
            color: #333;
            margin-bottom: 10px;
        }
        .subtitle {
            color: #666;
            margin-bottom: 30px;
        }
        .chart-container {
            position: relative;
            height: 500px;
            margin-top: 20px;
        }
        .stats {
            margin-top: 30px;
            padding: 20px;
            background-color: #f9f9f9;
            border-radius: 4px;
        }
        .stats h2 {
            margin-top: 0;
            color: #333;
        }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-top: 15px;
        }
        .stat-card {
            background-color: white;
            padding: 15px;
            border-radius: 4px;
            border: 1px solid #e0e0e0;
        }
        .stat-label {
            font-size: 12px;
            color: #666;
            margin-bottom: 5px;
        }
        .stat-value {
            font-size: 24px;
            font-weight: bold;
            color: #333;
        }
        .trend-analysis {
            margin-top: 20px;
            padding: 15px;
            background-color: #e8f4f8;
            border-left: 4px solid #2196F3;
            border-radius: 4px;
        }
        .trend-analysis h3 {
            margin-top: 0;
            color: #1976D2;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Gas Usage Over Time - Delegation Gas Bound Test</h1>
        <p class="subtitle">
            This chart shows the gas usage for <code>REQUEST_DEPOSIT_THEN_DELEGATE_TO</code> messages over time.<br>
            X-axis: Message sequence number (starting from 1 - oldest to newest)<br>
            Y-axis: Gas Used<br>
            Total messages: ${records.length}
        </p>
        
        <div class="chart-container">
            <canvas id="gasChart"></canvas>
        </div>
        
        <div class="stats">
            <h2>Statistics</h2>
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="stat-label">Total Messages</div>
                    <div class="stat-value">${records.length}</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">Min Gas</div>
                    <div class="stat-value">${minGas.toLocaleString()}</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">Max Gas</div>
                    <div class="stat-value">${maxGas.toLocaleString()}</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">Avg Gas</div>
                    <div class="stat-value">${avgGas.toLocaleString()}</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">P50 (Median)</div>
                    <div class="stat-value">${p50.toLocaleString()}</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">P95</div>
                    <div class="stat-value">${p95.toLocaleString()}</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">P99</div>
                    <div class="stat-value">${p99.toLocaleString()}</div>
                </div>
            </div>
        </div>

        <div class="trend-analysis">
            <h3>Trend Analysis</h3>
            <p>
                <strong>Gas Range:</strong> ${minGas.toLocaleString()} - ${maxGas.toLocaleString()} (${((maxGas - minGas) / minGas * 100).toFixed(2)}% variation)<br>
                <strong>Average Gas:</strong> ${avgGas.toLocaleString()}<br>
                <strong>95th Percentile:</strong> ${p95.toLocaleString()} (${((p95 - avgGas) / avgGas * 100).toFixed(2)}% above average)<br>
                <strong>99th Percentile:</strong> ${p99.toLocaleString()} (${((p99 - avgGas) / avgGas * 100).toFixed(2)}% above average)
            </p>
        </div>
    </div>

    <script>
        const ctx = document.getElementById('gasChart').getContext('2d');
        const chartData = ${JSON.stringify(chartData)};
        
        new Chart(ctx, {
            type: 'line',
            data: {
                datasets: [{
                    label: 'Gas Used',
                    data: chartData.map(d => ({ x: d.x, y: d.y })),
                    borderColor: 'rgb(75, 192, 192)',
                    backgroundColor: 'rgba(75, 192, 192, 0.2)',
                    fill: false,
                    tension: 0.1,
                    pointRadius: 2,
                    pointHoverRadius: 6,
                    pointBackgroundColor: 'rgb(75, 192, 192)',
                    pointBorderColor: 'rgb(75, 192, 192)',
                    showLine: true,
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                interaction: {
                    mode: 'nearest',
                    intersect: false,
                    axis: 'x'
                },
                plugins: {
                    title: {
                        display: true,
                        text: 'Gas Usage Over Time for REQUEST_DEPOSIT_THEN_DELEGATE_TO Messages'
                    },
                    legend: {
                        display: true,
                        position: 'top'
                    },
                    tooltip: {
                        callbacks: {
                            title: function(context) {
                                const dataPoint = chartData[context[0].dataIndex];
                                return 'Sequence #' + dataPoint.x + ' (Nonce: ' + dataPoint.nonce + ')';
                            },
                            label: function(context) {
                                const dataPoint = chartData[context.dataIndex];
                                return [
                                    'Gas Used: ' + context.parsed.y.toLocaleString(),
                                    'Tx Hash: ' + dataPoint.txHash.substring(0, 10) + '...'
                                ];
                            },
                            afterLabel: function(context) {
                                const dataPoint = chartData[context.dataIndex];
                                return 'Full Hash: ' + dataPoint.txHash;
                            }
                        }
                    }
                },
                scales: {
                    x: {
                        type: 'linear',
                        title: {
                            display: true,
                            text: 'Message Sequence Number (starting from 1)'
                        },
                        min: 0,
                        max: ${records.length},
                        ticks: {
                            stepSize: Math.max(1, Math.floor(${records.length} / 20)),
                            callback: function(value) {
                                return Number.isInteger(value) ? value : '';
                            }
                        }
                    },
                    y: {
                        title: {
                            display: true,
                            text: 'Gas Used'
                        },
                        min: ${yMin},
                        max: ${yMax},
                        ticks: {
                            callback: function(value) {
                                return value.toLocaleString();
                            }
                        }
                    }
                }
            }
        });
    </script>
</body>
</html>`;

  // Write HTML file
  const outputPath = path.resolve(process.cwd(), "gas-bound-visualization.html");
  await fs.writeFile(outputPath, html);
  console.log(`\n✓ Visualization saved to ${outputPath}`);
  console.log(`  Open the file in a web browser to view the chart.`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});

