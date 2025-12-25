import { promises as fs } from "fs";
import path from "path";

interface GasData {
  txHash: string;
  blockNumber: number;
  blockTimestamp: number;
  nonce: number;
  guid: string;
  messageType: string;
  actionValue: number;
  executionType: string;
  txGasLimit: string;
  endpointLzReceiveGasUsed: number;
  assetsPrecompileGasUsed?: number;
  delegationPrecompileGasUsed?: number;
  totalPrecompileGasUsed: number;
}

function parseCSV(csvContent: string): GasData[] {
  const lines = csvContent.trim().split("\n");
  if (lines.length < 2) return [];
  
  const headers = lines[0].split(",");
  const records: GasData[] = [];
  
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    
    const values = line.split(",");
    const record: any = {};
    
    for (let j = 0; j < headers.length; j++) {
      const header = headers[j];
      const value = values[j] || "";
      
      // Convert numeric columns
      if (header === "blockNumber" || 
          header === "blockTimestamp" ||
          header === "nonce" ||
          header === "actionValue" ||
          header === "endpointLzReceiveGasUsed" ||
          header === "assetsPrecompileGasUsed" ||
          header === "delegationPrecompileGasUsed" ||
          header === "totalPrecompileGasUsed") {
        const num = parseInt(value, 10);
        record[header] = isNaN(num) ? undefined : num;
      } else {
        record[header] = value;
      }
    }
    
    records.push(record as GasData);
  }
  
  return records;
}

async function main() {
  console.log("=== Gas Usage Visualization Generator ===\n");

  // Read CSV file
  const csvPath = path.resolve(process.cwd(), "gas-analysis-results.csv");
  console.log(`Reading CSV from ${csvPath}...`);
  
  const csvContent = await fs.readFile(csvPath, "utf-8");
  const records = parseCSV(csvContent);

  console.log(`Loaded ${records.length} records`);

  // Sort by nonce (chronological order)
  records.sort((a, b) => a.nonce - b.nonce);

  // Group by message type
  const byType: Record<string, GasData[]> = {};
  for (const record of records) {
    if (!byType[record.messageType]) {
      byType[record.messageType] = [];
    }
    byType[record.messageType].push(record);
  }

  console.log(`\nMessage types found:`);
  for (const [type, data] of Object.entries(byType)) {
    console.log(`  ${type}: ${data.length} messages`);
  }

  // Prepare data for Chart.js
  // Each message type gets multiple datasets: endpoint gas, assets precompile, delegation precompile
  interface MessageTypeDatasets {
    messageType: string;
    datasets: Array<any>;
  }
  
  const messageTypeDatasets: MessageTypeDatasets[] = [];

  // Color palette for different message types (for endpoint gas)
  const messageTypeColors = [
    { border: "rgb(75, 192, 192)", background: "rgba(75, 192, 192, 0.2)" },
    { border: "rgb(255, 99, 132)", background: "rgba(255, 99, 132, 0.2)" },
    { border: "rgb(54, 162, 235)", background: "rgba(54, 162, 235, 0.2)" },
    { border: "rgb(255, 206, 86)", background: "rgba(255, 206, 86, 0.2)" },
    { border: "rgb(153, 102, 255)", background: "rgba(153, 102, 255, 0.2)" },
    { border: "rgb(255, 159, 64)", background: "rgba(255, 159, 64, 0.2)" },
    { border: "rgb(199, 199, 199)", background: "rgba(199, 199, 199, 0.2)" },
    { border: "rgb(83, 102, 255)", background: "rgba(83, 102, 255, 0.2)" },
    { border: "rgb(255, 99, 255)", background: "rgba(255, 99, 255, 0.2)" },
    { border: "rgb(99, 255, 132)", background: "rgba(99, 255, 132, 0.2)" },
  ];

  // Precompile gas colors
  const assetsPrecompileColor = { border: "rgb(255, 99, 132)", background: "rgba(255, 99, 132, 0.1)" }; // Red/Pink
  const delegationPrecompileColor = { border: "rgb(54, 162, 235)", background: "rgba(54, 162, 235, 0.1)" }; // Blue

  let colorIndex = 0;
  let maxXValue = 0; // Track the maximum X value across all datasets

  // For each message type, create multiple datasets
  for (const [messageType, messages] of Object.entries(byType)) {
    const messageColor = messageTypeColors[colorIndex % messageTypeColors.length];
    colorIndex++;

    // Sort messages by nonce (chronological order) for this message type
    const sortedMessages = [...messages].sort((a, b) => a.nonce - b.nonce);

    // Create datasets for this message type
    const typeDatasets: Array<any> = [];

    // 1. Endpoint lzReceive gas dataset
    const endpointData = sortedMessages.map((msg, index) => {
      const xValue = index + 1;
      maxXValue = Math.max(maxXValue, xValue);
      return {
        x: xValue,
        y: msg.endpointLzReceiveGasUsed,
      };
    });

    typeDatasets.push({
      label: "Endpoint lzReceive Gas",
      data: endpointData,
      borderColor: messageColor.border,
      backgroundColor: messageColor.background,
      fill: false,
      tension: 0.1,
      pointRadius: 2,
      pointHoverRadius: 4,
      pointBackgroundColor: messageColor.border,
      pointBorderColor: messageColor.border,
      showLine: true,
    });

    // 2. Assets precompile gas dataset (if any messages have it)
    const hasAssetsPrecompile = sortedMessages.some(msg => msg.assetsPrecompileGasUsed !== undefined && msg.assetsPrecompileGasUsed > 0);
    if (hasAssetsPrecompile) {
      const assetsData = sortedMessages.map((msg, index) => {
        return {
          x: index + 1,
          y: msg.assetsPrecompileGasUsed || 0,
        };
      });

      typeDatasets.push({
        label: "Assets Precompile Gas",
        data: assetsData,
        borderColor: assetsPrecompileColor.border,
        backgroundColor: assetsPrecompileColor.background,
        fill: false,
        tension: 0.1,
        pointRadius: 2,
        pointHoverRadius: 4,
        pointBackgroundColor: assetsPrecompileColor.border,
        pointBorderColor: assetsPrecompileColor.border,
        showLine: true,
        borderDash: [5, 5], // Dashed line to differentiate
      });
    }

    // 3. Delegation precompile gas dataset (if any messages have it)
    const hasDelegationPrecompile = sortedMessages.some(msg => msg.delegationPrecompileGasUsed !== undefined && msg.delegationPrecompileGasUsed > 0);
    if (hasDelegationPrecompile) {
      const delegationData = sortedMessages.map((msg, index) => {
        return {
          x: index + 1,
          y: msg.delegationPrecompileGasUsed || 0,
        };
      });

      typeDatasets.push({
        label: "Delegation Precompile Gas",
        data: delegationData,
        borderColor: delegationPrecompileColor.border,
        backgroundColor: delegationPrecompileColor.background,
        fill: false,
        tension: 0.1,
        pointRadius: 2,
        pointHoverRadius: 4,
        pointBackgroundColor: delegationPrecompileColor.border,
        pointBorderColor: delegationPrecompileColor.border,
        showLine: true,
        borderDash: [5, 5], // Dashed line to differentiate
      });
    }

    messageTypeDatasets.push({
      messageType,
      datasets: typeDatasets,
    });
    
    console.log(`  ${messageType}: ${sortedMessages.length} messages, X range: 1 to ${sortedMessages.length}`);
  }

  console.log(`\nMaximum X value across all datasets: ${maxXValue}`);

  // Generate HTML with separate charts for each message type
  const chartSections = messageTypeDatasets.map((typeData, index) => {
    const messageType = typeData.messageType;
    const allDataPoints = typeData.datasets.flatMap(ds => ds.data);
    const maxX = Math.max(...allDataPoints.map(d => d.x));
    const maxY = Math.max(...allDataPoints.map(d => d.y));
    const minY = Math.min(...allDataPoints.map(d => d.y));
    
    // Get endpoint gas stats for subtitle
    const endpointDataset = typeData.datasets.find(ds => ds.label === "Endpoint lzReceive Gas");
    const endpointGasValues = endpointDataset ? endpointDataset.data.map(d => d.y) : [];
    const endpointMin = endpointGasValues.length > 0 ? Math.min(...endpointGasValues) : 0;
    const endpointMax = endpointGasValues.length > 0 ? Math.max(...endpointGasValues) : 0;
    const endpointAvg = endpointGasValues.length > 0 
      ? Math.round(endpointGasValues.reduce((sum, g) => sum + g, 0) / endpointGasValues.length)
      : 0;
    
    // Calculate Y-axis range with some padding
    const yPadding = (maxY - minY) * 0.1;
    const yMin = Math.max(0, minY - yPadding);
    const yMax = maxY + yPadding;
    
    return `
        <div class="chart-section">
            <h2>${messageType}</h2>
            <p class="chart-subtitle">
                ${endpointDataset?.data.length || 0} messages | 
                Endpoint Gas - Min: ${endpointMin.toLocaleString()} | Max: ${endpointMax.toLocaleString()} | Avg: ${endpointAvg.toLocaleString()}
            </p>
            <div class="chart-container">
                <canvas id="chart${index}"></canvas>
            </div>
        </div>
    `;
  }).join("\n");

  const chartScripts = messageTypeDatasets.map((typeData, index) => {
    const allDataPoints = typeData.datasets.flatMap(ds => ds.data);
    const maxX = Math.max(...allDataPoints.map(d => d.x));
    const maxY = Math.max(...allDataPoints.map(d => d.y));
    const minY = Math.min(...allDataPoints.map(d => d.y));
    const yPadding = (maxY - minY) * 0.1;
    const yMin = Math.max(0, minY - yPadding);
    const yMax = maxY + yPadding;
    
    return `
        const ctx${index} = document.getElementById('chart${index}').getContext('2d');
        new Chart(ctx${index}, {
            type: 'line',
            data: {
                datasets: ${JSON.stringify(typeData.datasets)}
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
                        display: false
                    },
                    legend: {
                        display: true,
                        position: 'top'
                    },
                    tooltip: {
                        callbacks: {
                            title: function(context) {
                                return 'Sequence #' + context[0].parsed.x;
                            },
                            label: function(context) {
                                return context.dataset.label + ': ' + context.parsed.y.toLocaleString() + ' gas';
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
                        max: ${maxX},
                        ticks: {
                            stepSize: Math.max(1, Math.floor(${maxX} / 15)),
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
    `;
  }).join("\n");

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Gas Usage Over Time by Message Type</title>
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
        .chart-section {
            margin-bottom: 60px;
            padding: 20px;
            background-color: #fafafa;
            border-radius: 8px;
            border: 1px solid #e0e0e0;
        }
        .chart-section h2 {
            color: #333;
            margin-top: 0;
            margin-bottom: 10px;
        }
        .chart-subtitle {
            color: #666;
            font-size: 14px;
            margin-bottom: 15px;
        }
        .chart-container {
            position: relative;
            height: 400px;
            margin-top: 10px;
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
        .stats table {
            width: 100%;
            border-collapse: collapse;
        }
        .stats th, .stats td {
            padding: 8px 12px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        .stats th {
            background-color: #e9e9e9;
            font-weight: bold;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Gas Usage Over Time by Message Type</h1>
        <p class="subtitle">
            Each message type has its own dedicated chart below.<br>
            <b>Solid lines</b> show the endpoint <code>lzReceive</code> gas usage.<br>
            <b>Dashed lines</b> show individual precompile gas usage (if applicable).<br>
            X-axis: Message sequence number (starting from 1 - oldest to newest)<br>
            Y-axis: Gas Used<br>
            Total messages: ${records.length}
        </p>
        
        ${chartSections}
        
        <div class="stats">
            <h2>Summary Statistics</h2>
            <table>
                <thead>
                    <tr>
                        <th>Message Type</th>
                        <th>Count</th>
                        <th>Min Gas</th>
                        <th>Max Gas</th>
                        <th>Avg Gas</th>
                    </tr>
                </thead>
                <tbody>
                    ${Object.entries(byType)
                      .map(([type, msgs]) => {
                        const gasValues = msgs.map((m) => m.endpointLzReceiveGasUsed);
                        const min = Math.min(...gasValues);
                        const max = Math.max(...gasValues);
                        const avg = Math.round(
                          gasValues.reduce((sum, g) => sum + g, 0) / gasValues.length
                        );
                        return `<tr>
                            <td>${type}</td>
                            <td>${msgs.length}</td>
                            <td>${min.toLocaleString()}</td>
                            <td>${max.toLocaleString()}</td>
                            <td>${avg.toLocaleString()}</td>
                        </tr>`;
                      })
                      .join("\n")}
                </tbody>
            </table>
        </div>
    </div>

    <script>
        ${chartScripts}
    </script>
</body>
</html>`;

  // Write HTML file
  const outputPath = path.resolve(process.cwd(), "gas-usage-visualization.html");
  await fs.writeFile(outputPath, html);
  console.log(`\n✓ Visualization saved to ${outputPath}`);
  console.log(`  Open the file in a web browser to view the chart.`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});

