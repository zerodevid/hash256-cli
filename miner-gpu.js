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
  let gpuProcess = null;

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

        if (gpuProcess) {
          gpuProcess.kill();
        }

        // Convert difficulty to hex for the C++ program
        const diffHex = BigInt(difficulty).toString(16).padStart(64, "0");
        const challHex = challenge.replace("0x", "");

        // Spawn GPU Miner
        // Arguments: challenge_hex difficulty_hex start_nonce
        const startNonce = Math.floor(Math.random() * 10000000).toString();
        gpuProcess = spawn("./cuda_miner", [challHex, diffHex, startNonce]);

        gpuProcess.stdout.on("data", async (data) => {
          const nonce = data.toString().trim();
          if (nonce) {
            console.log("\n======================================================");
            console.log("🎉 GPU FOUND VALID NONCE:", nonce);
            console.log("======================================================");
            
            try {
              console.log("⏳ Submitting TX...");
              const tx = await contract.mine(nonce);
              console.log("✅ TX sent:", tx.hash);
              await tx.wait();
              console.log("🔥 Success!");
            } catch (err) {
              console.error("❌ TX failed:", err.message);
            }
            updateChallenge(); // Refresh immediately
          }
        });

        gpuProcess.stderr.on("data", (data) => {
          // console.log(`GPU Log: ${data}`);
        });
      }
    } catch (err) {
      // console.error("Error fetching state:", err.message);
    }
  }

  await updateChallenge();
  setInterval(updateChallenge, 10000); // Check every 10 seconds
}

main().catch(console.error);
