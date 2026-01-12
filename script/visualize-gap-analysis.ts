import { promises as fs } from "fs";
import path from "path";

interface GapData {
  txHash: string;
  messageType: string;
  nonce: number;
  endpointGas: number;
  gatewayGas: number;
  gap: number;
  gapPercentage: number;
  success: boolean;
}

interface MessageTypeStats {
  messageType: string;
  count: number;
  minGap: number;
  maxGap: number;
  avgGap: number;
  p50: number;
  p95: number;
  p99: number;
  minGapPercentage: number;
  maxGapPercentage: number;
  avgGapPercentage: number;
  records: GapData[];
}

function parseCSV(csvContent: string): GapData[] {
  const lines = csvContent.trim().split("\n");
  if (lines.length < 2) return [];
  
  const headers = lines[0].split(",");
  const records: GapData[] = [];
  
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    
    const values = line.split(",");
    const record: any = {};
    
    for (let j = 0; j < headers.length; j++) {
      const header = headers[j];
      const value = values[j] || "";
      
      // Convert numeric columns
      if (header === "nonce" || 
          header === "endpointGas" || 
          header === "gatewayGas" || 
          header === "gap" || 
          header === "gapPercentage") {
        const num = parseFloat(value);
        record[header] = isNaN(num) ? undefined : num;
      } else if (header === "success") {
        record[header] = value === "true";
      } else {
        record[header] = value;
      }
    }
    
    // Only include successful analyses
    if (record.success) {
      records.push(record as GapData);
    }
  }
  
  return records;
}

function calculateStats(messageType: string, records: GapData[]): MessageTypeStats {
  const gaps = records.map(r => r.gap);
  const gapPercentages = records.map(r => r.gapPercentage);
  const sortedGaps = [...gaps].sort((a, b) => a - b);
  const sortedPercentages = [...gapPercentages].sort((a, b) => a - b);
  
  return {
    messageType,
    count: records.length,
    minGap: Math.min(...gaps),
    maxGap: Math.max(...gaps),
    avgGap: Math.round(gaps.reduce((sum, g) => sum + g, 0) / gaps.length),
    p50: sortedGaps[Math.floor(sortedGaps.length * 0.5)],
    p95: sortedGaps[Math.floor(sortedGaps.length * 0.95)],
    p99: sortedGaps[Math.floor(sortedGaps.length * 0.99)],
    minGapPercentage: Math.min(...gapPercentages),
    maxGapPercentage: Math.max(...gapPercentages),
    avgGapPercentage: Math.round((gapPercentages.reduce((sum, g) => sum + g, 0) / gapPercentages.length) * 100) / 100,
    records
  };
}

async function main() {
  console.log("=== Gap Analysis Visualization Generator ===\n");

  // Read CSV file
  const csvPath = path.resolve(process.cwd(), "lzreceive-gap-analysis.csv");
  console.log(`Reading CSV from ${csvPath}...`);
  
  const csvContent = await fs.readFile(csvPath, "utf-8");
  const records = parseCSV(csvContent);

  console.log(`Loaded ${records.length} successful gap analyses`);

  // Group records by message type
  const messageTypeGroups = new Map<string, GapData[]>();
  for (const record of records) {
    if (!messageTypeGroups.has(record.messageType)) {
      messageTypeGroups.set(record.messageType, []);
    }
    messageTypeGroups.get(record.messageType)!.push(record);
  }

  // Sort records within each group by nonce
  for (const [messageType, groupRecords] of messageTypeGroups.entries()) {
    groupRecords.sort((a, b) => a.nonce - b.nonce);
  }

  // Calculate statistics for each message type
  const stats: MessageTypeStats[] = [];
  for (const [messageType, groupRecords] of messageTypeGroups.entries()) {
    stats.push(calculateStats(messageType, groupRecords));
  }

  // Sort stats by average gap (for consistent ordering)
  stats.sort((a, b) => a.avgGap - b.avgGap);

  // Print statistics to console
  console.log(`\n=== Statistics by Message Type ===`);
  for (const stat of stats) {
    console.log(`\n${stat.messageType}:`);
    console.log(`  Count: ${stat.count}`);
    console.log(`  Gap (gas): Min=${stat.minGap.toLocaleString()}, Max=${stat.maxGap.toLocaleString()}, Avg=${stat.avgGap.toLocaleString()}`);
    console.log(`  Gap (%): Min=${stat.minGapPercentage.toFixed(2)}%, Max=${stat.maxGapPercentage.toFixed(2)}%, Avg=${stat.avgGapPercentage.toFixed(2)}%`);
    console.log(`  Percentiles: P50=${stat.p50.toLocaleString()}, P95=${stat.p95.toLocaleString()}, P99=${stat.p99.toLocaleString()}`);
  }

  // Prepare data for comparison chart
  const comparisonData = stats.map(s => ({
    messageType: s.messageType,
    avgGap: s.avgGap,
    minGap: s.minGap,
    maxGap: s.maxGap,
    p95: s.p95
  }));

  // Prepare chart data for each message type
  for (const stat of stats) {
    (stat as any).chartData = stat.records.map((record, index) => ({
      x: index + 1,
      y: record.gap,
      yPercentage: record.gapPercentage,
      nonce: record.nonce,
      txHash: record.txHash,
      endpointGas: record.endpointGas,
      gatewayGas: record.gatewayGas
    }));
  }

  // Color palette
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

  // Generate HTML
  const statsJson = JSON.stringify(stats);
  const comparisonDataJson = JSON.stringify(comparisonData);
  const colorsJson = JSON.stringify(colors);

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LZReceive Gap Analysis Visualization</title>
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
        .message-type-section {
            margin-top: 50px;
        }
        .message-type-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
        }
        .message-type-name {
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
        .chart-tabs {
            margin-bottom: 20px;
        }
        .chart-tabs button {
            padding: 8px 16px;
            margin-right: 10px;
            border: 1px solid #ddd;
            background-color: #f9f9f9;
            cursor: pointer;
            border-radius: 4px;
        }
        .chart-tabs button.active {
            background-color: #2196F3;
            color: white;
            border-color: #2196F3;
        }
        .chart-wrapper {
            display: none;
        }
        .chart-wrapper.active {
            display: block;
        }
    </style>
</head>
<body>
    <div class="nav-links">
        <strong>Quick Navigation:</strong>
        ${stats.map((s, idx) => `<a href="#message-type-${idx}">${s.messageType}</a>`).join('')}
    </div>

    <div class="container">
        <h1>LZReceive Gap Analysis Visualization</h1>
        <p class="subtitle">
            Analysis of gas gap between endpoint.lzReceive and gateway.lzReceive calls.<br>
            Total successful analyses: ${records.length}
        </p>
        
        <h2>Comparison: Average Gap by Message Type</h2>
        <div class="chart-container">
            <canvas id="comparisonChart"></canvas>
        </div>

        <h2>Statistics Summary</h2>
        <table class="stats-table">
            <thead>
                <tr>
                    <th>Message Type</th>
                    <th>Count</th>
                    <th>Min Gap</th>
                    <th>Max Gap</th>
                    <th>Avg Gap</th>
                    <th>P50</th>
                    <th>P95</th>
                    <th>P99</th>
                    <th>Avg Gap %</th>
                </tr>
            </thead>
            <tbody>
                ${stats.map(s => `
                <tr>
                    <td><strong>${s.messageType}</strong></td>
                    <td>${s.count}</td>
                    <td>${s.minGap.toLocaleString()}</td>
                    <td>${s.maxGap.toLocaleString()}</td>
                    <td>${s.avgGap.toLocaleString()}</td>
                    <td>${s.p50.toLocaleString()}</td>
                    <td>${s.p95.toLocaleString()}</td>
                    <td>${s.p99.toLocaleString()}</td>
                    <td>${s.avgGapPercentage.toFixed(2)}%</td>
                </tr>
                `).join('')}
            </tbody>
        </table>

        ${stats.map((s, idx) => {
            const chartData = (s as any).chartData || [];
            const color = colors[idx % colors.length];
            const gapRange = s.maxGap - s.minGap;
            const yPadding = gapRange > 0 ? gapRange * 0.1 : s.minGap * 0.1 || 1000;
            const yMin = Math.max(0, s.minGap - yPadding);
            const yMax = s.maxGap + yPadding;
            const pctRange = s.maxGapPercentage - s.minGapPercentage;
            const pctPadding = pctRange > 0 ? pctRange * 0.1 : s.minGapPercentage * 0.1 || 1;
            const pctMin = Math.max(0, s.minGapPercentage - pctPadding);
            const pctMax = s.maxGapPercentage + pctPadding;
            
            return `
        <div class="message-type-section" id="message-type-${idx}">
            <div class="message-type-header">
                <h2 class="message-type-name">${s.messageType}</h2>
            </div>
            <div class="chart-tabs">
                <button class="tab-button active" onclick="switchTab(${idx}, 'gap')">Gap (Gas Units)</button>
                <button class="tab-button" onclick="switchTab(${idx}, 'percentage')">Gap Percentage</button>
            </div>
            <div class="chart-wrapper active" id="chart-gap-${idx}">
                <div class="chart-container">
                    <canvas id="chart-${idx}"></canvas>
                </div>
            </div>
            <div class="chart-wrapper" id="chart-percentage-${idx}">
                <div class="chart-container">
                    <canvas id="chart-percentage-${idx}-canvas"></canvas>
                </div>
            </div>
            <table class="stats-table">
                <thead>
                    <tr>
                        <th>Metric</th>
                        <th>Value</th>
                    </tr>
                </thead>
                <tbody>
                    <tr><td>Count</td><td>${s.count}</td></tr>
                    <tr><td>Min Gap</td><td>${s.minGap.toLocaleString()} gas</td></tr>
                    <tr><td>Max Gap</td><td>${s.maxGap.toLocaleString()} gas</td></tr>
                    <tr><td>Avg Gap</td><td>${s.avgGap.toLocaleString()} gas</td></tr>
                    <tr><td>P50 Gap</td><td>${s.p50.toLocaleString()} gas</td></tr>
                    <tr><td>P95 Gap</td><td>${s.p95.toLocaleString()} gas</td></tr>
                    <tr><td>P99 Gap</td><td>${s.p99.toLocaleString()} gas</td></tr>
                    <tr><td>Avg Gap %</td><td>${s.avgGapPercentage.toFixed(2)}%</td></tr>
                    <tr><td>Min Gap %</td><td>${s.minGapPercentage.toFixed(2)}%</td></tr>
                    <tr><td>Max Gap %</td><td>${s.maxGapPercentage.toFixed(2)}%</td></tr>
                </tbody>
            </table>
        </div>
        <script>
            (function() {
                const stats = ${statsJson};
                const stat = stats[${idx}];
                const chartData = ${JSON.stringify(chartData)};
                const color = '${color}';
                
                // Gap chart (gas units)
                const ctx = document.getElementById('chart-${idx}').getContext('2d');
                const isSinglePoint = chartData.length === 1;
                const datasets = [{
                    label: 'Gap (Gas Units)',
                    data: chartData.map(d => ({ x: d.x, y: d.y })),
                    borderColor: color,
                    backgroundColor: color.replace('rgb(', 'rgba(').replace(')', ', 0.2)'),
                    fill: false,
                    tension: 0.1,
                    pointRadius: isSinglePoint ? 8 : 2,
                    pointHoverRadius: isSinglePoint ? 12 : 6,
                }];
                
                // For single point, add a horizontal reference line
                if (isSinglePoint) {
                    datasets.push({
                        label: 'Reference Line',
                        data: [
                            { x: 0, y: chartData[0].y },
                            { x: ${s.count}, y: chartData[0].y }
                        ],
                        borderColor: color.replace('rgb(', 'rgba(').replace(')', ', 0.3)'),
                        borderDash: [5, 5],
                        pointRadius: 0,
                        pointHoverRadius: 0,
                        fill: false,
                    });
                }
                
                new Chart(ctx, {
                    type: 'line',
                    data: {
                        datasets: datasets
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        plugins: {
                            title: {
                                display: true,
                                text: 'Gap Over Time: ${s.messageType} (Gas Units)' + (isSinglePoint ? ' - Single Data Point' : '')
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
                                            'Gap: ' + context.parsed.y.toLocaleString() + ' gas',
                                            'Gap %: ' + dataPoint.yPercentage.toFixed(2) + '%',
                                            'Endpoint Gas: ' + dataPoint.endpointGas.toLocaleString(),
                                            'Gateway Gas: ' + dataPoint.gatewayGas.toLocaleString(),
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
                                title: { display: true, text: 'Message Sequence Number' },
                                min: 0,
                                max: Math.max(1, ${s.count}),
                            },
                            y: {
                                title: { display: true, text: 'Gap (Gas Units)' },
                                min: ${yMin},
                                max: ${yMax},
                            }
                        }
                    }
                });
                
                // Gap percentage chart
                const ctxPct = document.getElementById('chart-percentage-${idx}-canvas').getContext('2d');
                const datasetsPct = [{
                    label: 'Gap Percentage',
                    data: chartData.map(d => ({ x: d.x, y: d.yPercentage })),
                    borderColor: color,
                    backgroundColor: color.replace('rgb(', 'rgba(').replace(')', ', 0.2)'),
                    fill: false,
                    tension: 0.1,
                    pointRadius: isSinglePoint ? 8 : 2,
                    pointHoverRadius: isSinglePoint ? 12 : 6,
                }];
                
                // For single point, add a horizontal reference line
                if (isSinglePoint) {
                    datasetsPct.push({
                        label: 'Reference Line',
                        data: [
                            { x: 0, y: chartData[0].yPercentage },
                            { x: ${s.count}, y: chartData[0].yPercentage }
                        ],
                        borderColor: color.replace('rgb(', 'rgba(').replace(')', ', 0.3)'),
                        borderDash: [5, 5],
                        pointRadius: 0,
                        pointHoverRadius: 0,
                        fill: false,
                    });
                }
                
                new Chart(ctxPct, {
                    type: 'line',
                    data: {
                        datasets: datasetsPct
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        plugins: {
                            title: {
                                display: true,
                                text: 'Gap Over Time: ${s.messageType} (Percentage)' + (isSinglePoint ? ' - Single Data Point' : '')
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
                                            'Gap %: ' + context.parsed.y.toFixed(2) + '%',
                                            'Gap: ' + dataPoint.y.toLocaleString() + ' gas',
                                            'Endpoint Gas: ' + dataPoint.endpointGas.toLocaleString(),
                                            'Gateway Gas: ' + dataPoint.gatewayGas.toLocaleString(),
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
                                title: { display: true, text: 'Message Sequence Number' },
                                min: 0,
                                max: Math.max(1, ${s.count}),
                            },
                            y: {
                                title: { display: true, text: 'Gap Percentage (%)' },
                                min: ${pctMin},
                                max: ${pctMax},
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
        const comparisonData = ${comparisonDataJson};
        const colors = ${colorsJson};
        
        // Comparison chart
        const comparisonCtx = document.getElementById('comparisonChart').getContext('2d');
        new Chart(comparisonCtx, {
            type: 'bar',
            data: {
                labels: comparisonData.map(d => d.messageType),
                datasets: [
                    {
                        label: 'Average Gap',
                        data: comparisonData.map(d => d.avgGap),
                        backgroundColor: colors.map((c, i) => c.replace('rgb(', 'rgba(').replace(')', ', 0.7)')),
                        borderColor: colors,
                        borderWidth: 2
                    },
                    {
                        label: 'P95 Gap',
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
                        text: 'Gap Comparison: Average vs P95 by Message Type'
                    },
                    legend: {
                        display: true,
                        position: 'top'
                    },
                    tooltip: {
                        callbacks: {
                            label: function(context) {
                                return context.dataset.label + ': ' + context.parsed.y.toLocaleString() + ' gas';
                            }
                        }
                    }
                },
                scales: {
                    y: {
                        title: {
                            display: true,
                            text: 'Gap (Gas Units)'
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
        
        // Tab switching function
        function switchTab(idx, type) {
            // Hide all charts for this message type
            document.getElementById('chart-gap-' + idx).classList.remove('active');
            document.getElementById('chart-percentage-' + idx).classList.remove('active');
            
            // Show selected chart
            document.getElementById('chart-' + type + '-' + idx).classList.add('active');
            
            // Update button states
            const buttons = document.querySelectorAll('#message-type-' + idx + ' .tab-button');
            buttons.forEach(btn => btn.classList.remove('active'));
            event.target.classList.add('active');
        }
    </script>
</body>
</html>`;

  // Write HTML file
  const outputPath = path.resolve(process.cwd(), "gap-analysis-visualization.html");
  await fs.writeFile(outputPath, html);
  console.log(`\n✓ Visualization saved to ${outputPath}`);
  console.log(`  Open the file in a web browser to view the charts.`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
