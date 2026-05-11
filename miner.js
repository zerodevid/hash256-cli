require("dotenv").config();

const { ethers } = require("ethers");
const { Worker, isMainThread, parentPort, workerData } = require("worker_threads");
const os = require("os");
const crypto = require("crypto");

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const CONTRACT_ADDRESS = "0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc";

const ABI = [
  "function getChallenge(address miner) view returns (bytes32)",
  "function miningState() view returns (uint256 era,uint256 reward,uint256 difficulty,uint256 minted,uint256 remaining,uint256 epoch,uint256 epochBlocksLeft_)",
  "function mine(uint256 nonce)"
];

if (isMainThread) {
  // --- MAIN THREAD (ORCHESTRATOR) ---
  function requireEnv() {
    if (!RPC_URL || !PRIVATE_KEY) {
      console.error("Isi RPC_URL dan PRIVATE_KEY di file .env dulu.");
      process.exit(1);
    }
    if (!PRIVATE_KEY.startsWith("0x")) {
      console.error("PRIVATE_KEY harus diawali 0x.");
      process.exit(1);
    }
  }

  async function main() {
    requireEnv();

    const provider = new ethers.JsonRpcProvider(RPC_URL);
    const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
    const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

    console.log("======================================================");
    console.log(" 🚀 HASH256 FULL-POWER MULTI-CORE MINER STARTING...");
    console.log("======================================================");
    console.log("Wallet:", wallet.address);
    console.log("Contract:", CONTRACT_ADDRESS);
    
    // Automatically detect total logical CPU cores
    const numCPUs = os.cpus().length;
    console.log(`💻 Detected ${numCPUs} CPU Cores. Spawning ${numCPUs} workers...`);

    let currentChallenge = null;
    let currentDifficulty = null;
    let isSubmitting = false;

    const workers = [];
    let totalHashes = 0n;
    let startTime = Date.now();
    let lastReportTime = Date.now();
    let lastReportHashes = 0n;

    // Spawn workers
    for (let i = 0; i < numCPUs; i++) {
      const worker = new Worker(__filename, {
        workerData: { workerId: i }
      });

      worker.on("message", async (msg) => {
        if (msg.type === "hashCount") {
          totalHashes += BigInt(msg.count);
        } else if (msg.type === "found" && !isSubmitting) {
          isSubmitting = true;
          const { nonce, hash } = msg;

          console.log("\n======================================================");
          console.log("🎉 FOUND VALID NONCE!");
          console.log(`Worker ID : ${i}`);
          console.log(`Nonce     : ${nonce}`);
          console.log(`Hash      : ${hash}`);
          console.log("======================================================");
          
          // Pause all workers to save CPU while submitting
          for (const w of workers) w.postMessage({ type: "pause" });

          try {
            console.log("⏳ Submitting TX...");
            const tx = await contract.mine(nonce);
            console.log("✅ TX sent:", tx.hash);

            console.log("⏳ Waiting for confirmation...");
            const receipt = await tx.wait();
            console.log("🔥 Success at block:", receipt.blockNumber);
          } catch (err) {
            console.error("❌ TX failed:", err.shortMessage || err.message);
          }

          isSubmitting = false;
          // The updateChallenge loop will automatically fetch new challenge and resume workers
        }
      });

      worker.on("error", (err) => console.error(`Worker ${i} error:`, err));
      worker.on("exit", (code) => {
        if (code !== 0) console.error(`Worker ${i} stopped with exit code ${code}`);
      });

      workers.push(worker);
    }

    // Reporter Interval
    setInterval(() => {
      const now = Date.now();
      const elapsed = (now - lastReportTime) / 1000;
      if (elapsed >= 2) {
        const diffHashes = totalHashes - lastReportHashes;
        const hashrate = Number(diffHashes) / elapsed;
        
        let hashrateStr = "";
        if (hashrate > 1_000_000) hashrateStr = (hashrate / 1_000_000).toFixed(2) + " MH/s";
        else if (hashrate > 1_000) hashrateStr = (hashrate / 1_000).toFixed(2) + " kH/s";
        else hashrateStr = hashrate.toFixed(2) + " H/s";

        // Overwrite the current console line for clean output
        process.stdout.write(`\r[⚡ Hashrate: ${hashrateStr}] [Total Hashes: ${totalHashes}]`);
        
        lastReportTime = now;
        lastReportHashes = totalHashes;
      }
    }, 2000);

    // Watcher: Fetch challenge periodically to prevent stale mining
    async function updateChallenge() {
      if (isSubmitting) return;

      try {
        const state = await contract.miningState();
        const difficulty = BigInt(state.difficulty.toString());
        const challenge = await contract.getChallenge(wallet.address);

        if (challenge !== currentChallenge || difficulty !== currentDifficulty) {
          currentChallenge = challenge;
          currentDifficulty = difficulty;
          
          console.log(`\n\n🔄 New Block / Challenge Detected!`);
          console.log(`Challenge : ${challenge.substring(0,20)}...`);
          console.log(`Difficulty: ${difficulty.toString()}`);
          console.log(`Reward    : ${ethers.formatUnits(state.reward, 18)} HASH`);
          console.log(`Restarting all workers with new challenge...`);

          // Update and resume workers
          for (const w of workers) {
            w.postMessage({
              type: "update",
              challenge,
              difficulty: difficulty.toString()
            });
          }
        }
      } catch (err) {
        // Ignore silent RPC errors, will retry next interval
      }
    }

    await updateChallenge();
    setInterval(updateChallenge, 5000); // Check for new block every 5 seconds
  }

  main().catch((err) => {
    console.error("Critical Error:", err.shortMessage || err.message || err);
    process.exit(1);
  });

} else {
  // --- WORKER THREAD ---
  const nativeMiner = require("./build/Release/native_miner.node");

  let isMining = false;
  let buffer = Buffer.alloc(64);
  let diffBytes = Buffer.alloc(32);
  let hashCount = 0;

  // Function to convert buffer nonce back to BigInt for contract submission
  function bufferToBigInt(buf) {
    let hex = "0x";
    for (let i = 32; i < 64; i++) {
      hex += buf[i].toString(16).padStart(2, "0");
    }
    return BigInt(hex);
  }

  parentPort.on("message", (msg) => {
    if (msg.type === "pause") {
      isMining = false;
    } else if (msg.type === "update") {
      const diffHex = BigInt(msg.difficulty).toString(16).padStart(64, "0");
      for (let i = 0; i < 32; i++) {
        diffBytes[i] = parseInt(diffHex.slice(i * 2, i * 2 + 2), 16);
      }

      const challengeBytes = ethers.getBytes(msg.challenge);
      buffer.set(challengeBytes, 0);

      // Randomize the start nonce in the last 32 bytes so workers don't overlap
      crypto.randomFillSync(buffer, 32, 32);

      isMining = true;
      mine();
    }
  });

  setInterval(() => {
    if (hashCount > 0) {
      parentPort.postMessage({ type: "hashCount", count: hashCount });
      hashCount = 0;
    }
  }, 1000);

  function mine() {
    if (!isMining) return;

    // Run 100,000 iterations inside C++ (takes about 0.05-0.2 seconds per core)
    const iterations = 100000;
    const found = nativeMiner.mineLoop(buffer, diffBytes, iterations);

    if (found === 1) {
      const foundNonce = bufferToBigInt(buffer).toString();
      const hashHex = ethers.keccak256(buffer); // Re-calculate the winning hash just for display
      
      parentPort.postMessage({
        type: "found",
        nonce: foundNonce,
        hash: hashHex
      });
      isMining = false;
    } else {
      hashCount += iterations;
    }

    if (isMining) {
      setImmediate(mine);
    }
  }
}
