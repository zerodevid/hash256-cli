require("dotenv").config();
const { ethers } = require("ethers");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const CONTRACT_ADDRESS = "0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc";

const ABI = [
  "function getChallenge(address miner) view returns (bytes32)",
  "function miningState() view returns (uint256 era,uint256 reward,uint256 difficulty,uint256 minted,uint256 remaining,uint256 epoch,uint256 epochBlocksLeft_)",
  "function mine(uint256 nonce)"
];

async function main() {
  if (!RPC_URL || !PRIVATE_KEY) {
    console.error("Isi RPC_URL dan PRIVATE_KEY di file .env dulu.");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

  console.log("======================================================");
  console.log(" 🚀 HASH256 NVIDIA GPU MINER STARTING...");
  console.log("======================================================");
  console.log("Wallet:", wallet.address);

  // Compile CUDA miner if not exists
  const cudaBinary = path.join(__dirname, "cuda_miner");
  if (!fs.existsSync(cudaBinary)) {
    console.log("⏳ Compiling CUDA miner...");
    try {
      const { execSync } = require("child_process");
      execSync("nvcc -O3 cuda_miner.cu -o cuda_miner");
      console.log("✅ Compilation successful.");
    } catch (e) {
      console.error("❌ Failed to compile cuda_miner.cu. Make sure nvcc (CUDA) is installed.");
      process.exit(1);
    }
  }

  let currentChallenge = null;
  let currentDifficulty = null;
  let gpuProcesses = [];

  let gpuCount = 1;
  try {
    const { execSync } = require("child_process");
    const smiOutput = execSync("nvidia-smi -L").toString();
    gpuCount = smiOutput.trim().split("\n").filter(line => line.startsWith("GPU")).length;
    if (gpuCount === 0) gpuCount = 1;
  } catch (e) {
    console.log("⚠️ Could not detect GPU count using nvidia-smi. Defaulting to 1.");
  }
  console.log(`💻 Detected ${gpuCount} GPU(s). Multi-GPU Mining Enabled!`);

  async function updateChallenge() {
    try {
      const state = await contract.miningState();
      const difficulty = state.difficulty.toString();
      const challenge = await contract.getChallenge(wallet.address);

      if (challenge !== currentChallenge || difficulty !== currentDifficulty) {
        currentChallenge = challenge;
        currentDifficulty = difficulty;
        
        console.log(`\n🔄 New Challenge: ${challenge.substring(0,20)}...`);
        console.log(`Difficulty: ${difficulty}`);

        if (gpuProcesses.length > 0) {
          gpuProcesses.forEach(p => p.kill());
          gpuProcesses = [];
        }

        // Convert difficulty to hex for the C++ program
        const diffHex = BigInt(difficulty).toString(16).padStart(64, "0");
        const challHex = challenge.replace("0x", "");

        let hashrates = {};
        let lastReport = Date.now();

        // Spawn GPU Miner for each detected GPU
        for (let i = 0; i < gpuCount; i++) {
          // Spread start nonce space to prevent GPUs from overlapping
          const baseOffset = BigInt(i) * 1000000000000n; 
          const randOffset = BigInt(Math.floor(Math.random() * 1000000000));
          const startNonce = (baseOffset + randOffset).toString();

          const p = spawn("./cuda_miner", [challHex, diffHex, startNonce], {
             env: { ...process.env, CUDA_VISIBLE_DEVICES: i.toString() }
          });

          p.stdout.on("data", async (data) => {
            const nonce = data.toString().trim();
            if (nonce) {
              console.log("\n======================================================");
              console.log(`🎉 GPU [${i}] FOUND VALID NONCE:`, nonce);
              console.log("======================================================");
              
              if (currentChallenge !== challenge) return; 

              try {
                console.log(`⏳ Submitting TX (from GPU ${i}) with HIGH GWEI...`);
                
                // Get current network fee data
                const feeData = await provider.getFeeData();
                let txOptions = {};
                
                // Multiply gas prices by 2 (200%) to ensure it gets mined aggressively
                if (feeData.maxFeePerGas) {
                  txOptions.maxFeePerGas = (feeData.maxFeePerGas * 200n) / 100n;
                  // Handle potential 0n priority fee by setting a minimum if needed, but 2x is generally safe
                  const priorityFee = feeData.maxPriorityFeePerGas || 1000000000n; // fallback to 1 gwei if null
                  txOptions.maxPriorityFeePerGas = (priorityFee * 200n) / 100n;
                } else if (feeData.gasPrice) {
                  txOptions.gasPrice = (feeData.gasPrice * 200n) / 100n;
                }

                const tx = await contract.mine(nonce, txOptions);
                console.log(`✅ TX sent: ${tx.hash} (Gas Boosted 2x!)`);
                await tx.wait();
                console.log("🔥 Success!");
              } catch (err) {
                console.error("❌ TX failed:", err.message);
              }
              updateChallenge(); // Refresh immediately
            }
          });

          p.stderr.on("data", (data) => {
            const log = data.toString().trim();
            if (log.includes("Hashrate:")) {
              const match = log.match(/Hashrate: ([\d.]+) MH\/s/);
              if (match) {
                hashrates[i] = parseFloat(match[1]);
                if (Date.now() - lastReport > 2000) {
                  const total = Object.values(hashrates).reduce((a, b) => a + b, 0).toFixed(2);
                  const details = Object.entries(hashrates).map(([id, hr]) => `G${id}:${hr.toFixed(0)}`).join(" | ");
                  process.stdout.write(`\r🚀 Total: ${total} MH/s [ ${details} ]   `);
                  lastReport = Date.now();
                }
              }
            } else {
              console.log(`\nGPU [${i}] Log: ${log}`);
            }
          });

          gpuProcesses.push(p);
        }
      }
    } catch (err) {
      // console.error("Error fetching state:", err.message);
    }
  }

  await updateChallenge();
  setInterval(updateChallenge, 10000); // Check every 10 seconds
}

main().catch(console.error);
