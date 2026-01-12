import { promises as fs } from "fs";
import path from "path";

interface GasBoundData {
  action: string;
  nonce: number;
  txHash: string;
  gasUsed: number;
}

interface ActionStats {
  action: string;
  count: number;
  minGas: number;
  maxGas: number;
  avgGas: number;
  p50: number;
  p95: number;
  p99: number;
  records: GasBoundData[];
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

function calculateStats(action: string, records: GasBoundData[]): ActionStats {
  const gasValues = records.map(r => r.gasUsed);
  const sortedGas = [...gasValues].sort((a, b) => a - b);
  
  return {
    action,
    count: records.length,
    minGas: Math.min(...gasValues),
    maxGas: Math.max(...gasValues),
    avgGas: Math.round(gasValues.reduce((sum, g) => sum + g, 0) / gasValues.length),
    p50: sortedGas[Math.floor(sortedGas.length * 0.5)],
    p95: sortedGas[Math.floor(sortedGas.length * 0.95)],
    p99: sortedGas[Math.floor(sortedGas.length * 0.99)],
    records
  };
}

async function main() {
  console.log("=== Gas Bound Results Visualization Generator ===\n");

  // Read CSV file
  const csvPath = path.resolve(process.cwd(), "gas-bound-results.csv");
  console.log(`Reading CSV from ${csvPath}...`);
  
  const csvContent = await fs.readFile(csvPath, "utf-8");
  const records = parseCSV(csvContent);

  console.log(`Loaded ${records.length} records`);

  // Group records by action type
  const actionGroups = new Map<string, GasBoundData[]>();
  for (const record of records) {
    if (!actionGroups.has(record.action)) {
      actionGroups.set(record.action, []);
    }
    actionGroups.get(record.action)!.push(record);
  }

  // Sort records within each group by nonce
  for (const [action, groupRecords] of actionGroups.entries()) {
    groupRecords.sort((a, b) => a.nonce - b.nonce);
  }

  // Calculate statistics for each action type
  const actionStats: ActionStats[] = [];
  for (const [action, groupRecords] of actionGroups.entries()) {
    actionStats.push(calculateStats(action, groupRecords));
  }

  // Sort action stats by average gas (for consistent ordering)
  actionStats.sort((a, b) => a.avgGas - b.avgGas);

  // Print statistics to console
  console.log(`\n=== Statistics by Action Type ===`);
  for (const stats of actionStats) {
    console.log(`\n${stats.action}:`);
    console.log(`  Count: ${stats.count}`);
    console.log(`  Min Gas: ${stats.minGas.toLocaleString()}`);
    console.log(`  Max Gas: ${stats.maxGas.toLocaleString()}`);
    console.log(`  Avg Gas: ${stats.avgGas.toLocaleString()}`);
    console.log(`  P50 (Median): ${stats.p50.toLocaleString()}`);
    console.log(`  P95: ${stats.p95.toLocaleString()}`);
    console.log(`  P99: ${stats.p99.toLocaleString()}`);
  }

  // Prepare data for comparison chart (bar chart showing average gas per action)
  const comparisonData = actionStats.map(stats => ({
    action: stats.action,
    avgGas: stats.avgGas,
    minGas: stats.minGas,
    maxGas: stats.maxGas,
    p95: stats.p95
  }));

  // Prepare data for individual action charts - store directly in stats
  for (const stats of actionStats) {
    (stats as any).chartData = stats.records.map((record, index) => ({
      x: index + 1,
      y: record.gasUsed,
      nonce: record.nonce,
      txHash: record.txHash
    }));
  }

  // Color palette for different action types
  const colors = [
    'rgb(75, 192, 192)',   // Teal
    'rgb(255, 99, 132)',    // Red
    'rgb(54, 162, 235)',    // Blue
    'rgb(255, 206, 86)',    // Yellow
    'rgb(153, 102, 255)',   // Purple
    'rgb(255, 159, 64)',    // Orange
    'rgb(199, 199, 199)',   // Grey
    'rgb(83, 102, 255)',    // Indigo
    'rgb(255, 99, 255)',    // Magenta
  ];

  // Generate HTML with multiple charts
  const actionStatsJson = JSON.stringify(actionStats);
  const comparisonDataJson = JSON.stringify(comparisonData);
  const colorsJson = JSON.stringify(colors);

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Gas Usage Statistics - Delegation Gas Bound Test</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }
        .container {
            max-width: 1600px;
            margin: 0 auto;
            background-color: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 30px;
        }
        h1 {
            color: #333;
            margin-bottom: 10px;
        }
        h2 {
            color: #333;
            margin-top: 30px;
            margin-bottom: 15px;
            border-bottom: 2px solid #e0e0e0;
            padding-bottom: 10px;
        }
        .subtitle {
            color: #666;
            margin-bottom: 30px;
        }
        .chart-container {
            position: relative;
            height: 500px;
            margin-top: 20px;
            margin-bottom: 40px;
        }
        .stats-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
            background-color: white;
        }
        .stats-table th {
            background-color: #f9f9f9;
            padding: 12px;
            text-align: left;
            border-bottom: 2px solid #e0e0e0;
            font-weight: bold;
            color: #333;
        }
        .stats-table td {
            padding: 10px 12px;
            border-bottom: 1px solid #e0e0e0;
        }
        .stats-table tr:hover {
            background-color: #f5f5f5;
        }
        .action-section {
            margin-top: 50px;
        }
        .action-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
        }
        .action-name {
            font-size: 18px;
            font-weight: bold;
            color: #333;
        }
        .nav-links {
            margin-bottom: 20px;
            padding: 15px;
            background-color: #f9f9f9;
            border-radius: 4px;
        }
        .nav-links a {
            color: #2196F3;
            text-decoration: none;
            margin-right: 15px;
            padding: 5px 10px;
            border-radius: 3px;
        }
        .nav-links a:hover {
            background-color: #e3f2fd;
        }
    </style>
</head>
<body>
    <div class="nav-links">
        <strong>Quick Navigation:</strong>
        ${actionStats.map((stats, idx) => `<a href="#action-${idx}">${stats.action}</a>`).join('')}
    </div>

    <div class="container">
        <h1>Gas Usage Statistics - Delegation Gas Bound Test</h1>
        <p class="subtitle">
            Comprehensive gas usage analysis for all message types in the ImuachainGateway contract.<br>
            Total messages analyzed: ${records.length}
        </p>
        
        <h2>Comparison: Average Gas by Action Type</h2>
        <div class="chart-container">
            <canvas id="comparisonChart"></canvas>
        </div>

        <h2>Statistics Summary</h2>
        <table class="stats-table">
            <thead>
                <tr>
                    <th>Action Type</th>
                    <th>Count</th>
                    <th>Min Gas</th>
                    <th>Max Gas</th>
                    <th>Avg Gas</th>
                    <th>P50 (Median)</th>
                    <th>P95</th>
                    <th>P99</th>
                </tr>
            </thead>
            <tbody>
                ${actionStats.map(stats => `
                <tr>
                    <td><strong>${stats.action}</strong></td>
                    <td>${stats.count}</td>
                    <td>${stats.minGas.toLocaleString()}</td>
                    <td>${stats.maxGas.toLocaleString()}</td>
                    <td>${stats.avgGas.toLocaleString()}</td>
                    <td>${stats.p50.toLocaleString()}</td>
                    <td>${stats.p95.toLocaleString()}</td>
                    <td>${stats.p99.toLocaleString()}</td>
                </tr>
                `).join('')}
            </tbody>
        </table>

        ${actionStats.map((stats, idx) => {
            const chartData = (stats as any).chartData || [];
            const color = colors[idx % colors.length];
            // Handle case where all values are the same
            const gasRange = stats.maxGas - stats.minGas;
            const yPadding = gasRange > 0 ? gasRange * 0.1 : stats.minGas * 0.1 || 1000;
            const yMin = Math.max(0, stats.minGas - yPadding);
            const yMax = stats.maxGas + yPadding;
            
            return `
        <div class="action-section" id="action-${idx}">
            <div class="action-header">
                <h2 class="action-name">${stats.action}</h2>
            </div>
            <div class="chart-container">
                <canvas id="chart-${idx}"></canvas>
            </div>
            <table class="stats-table">
                <thead>
                    <tr>
                        <th>Metric</th>
                        <th>Value</th>
                    </tr>
                </thead>
                <tbody>
                    <tr><td>Count</td><td>${stats.count}</td></tr>
                    <tr><td>Min Gas</td><td>${stats.minGas.toLocaleString()}</td></tr>
                    <tr><td>Max Gas</td><td>${stats.maxGas.toLocaleString()}</td></tr>
                    <tr><td>Avg Gas</td><td>${stats.avgGas.toLocaleString()}</td></tr>
                    <tr><td>P50 (Median)</td><td>${stats.p50.toLocaleString()}</td></tr>
                    <tr><td>P95</td><td>${stats.p95.toLocaleString()}</td></tr>
                    <tr><td>P99</td><td>${stats.p99.toLocaleString()}</td></tr>
                    <tr><td>Variation</td><td>${((stats.maxGas - stats.minGas) / stats.minGas * 100).toFixed(2)}%</td></tr>
                </tbody>
            </table>
        </div>
        <script>
            (function() {
                const ctx = document.getElementById('chart-${idx}').getContext('2d');
                const chartData = ${JSON.stringify(chartData)};
                
                new Chart(ctx, {
                    type: 'line',
                    data: {
                        datasets: [{
                            label: 'Gas Used',
                            data: chartData.map(d => ({ x: d.x, y: d.y })),
                            borderColor: '${color}',
                            backgroundColor: '${color.replace('rgb(', 'rgba(').replace(')', ', 0.2)')}',
                            fill: false,
                            tension: 0.1,
                            pointRadius: 2,
                            pointHoverRadius: 6,
                            pointBackgroundColor: '${color}',
                            pointBorderColor: '${color}',
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
                                text: 'Gas Usage Over Time: ${stats.action}'
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
                                    text: 'Message Sequence Number'
                                },
                                min: 0,
                                max: ${stats.count},
                                ticks: {
                                    stepSize: Math.max(1, Math.floor(${stats.count} / 20)),
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
            })();
        </script>
            `;
        }).join('')}
    </div>

    <script>
        // Comparison chart
        const comparisonCtx = document.getElementById('comparisonChart').getContext('2d');
        const comparisonData = ${comparisonDataJson};
        const colors = ${colorsJson};
        
        new Chart(comparisonCtx, {
            type: 'bar',
            data: {
                labels: comparisonData.map(d => d.action),
                datasets: [
                    {
                        label: 'Average Gas',
                        data: comparisonData.map(d => d.avgGas),
                        backgroundColor: colors.map((c, i) => c.replace('rgb(', 'rgba(').replace(')', ', 0.7)')),
                        borderColor: colors,
                        borderWidth: 2
                    },
                    {
                        label: 'P95 Gas',
                        data: comparisonData.map(d => d.p95),
                        backgroundColor: colors.map((c, i) => c.replace('rgb(', 'rgba(').replace(')', ', 0.4)')),
                        borderColor: colors,
                        borderWidth: 1,
                        borderDash: [5, 5]
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    title: {
                        display: true,
                        text: 'Gas Usage Comparison: Average vs P95 by Action Type'
                    },
                    legend: {
                        display: true,
                        position: 'top'
                    },
                    tooltip: {
                        callbacks: {
                            label: function(context) {
                                return context.dataset.label + ': ' + context.parsed.y.toLocaleString();
                            }
                        }
                    }
                },
                scales: {
                    y: {
                        title: {
                            display: true,
                            text: 'Gas Used'
                        },
                        beginAtZero: true,
                        ticks: {
                            callback: function(value) {
                                return value.toLocaleString();
                            }
                        }
                    },
                    x: {
                        ticks: {
                            maxRotation: 45,
                            minRotation: 45
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

