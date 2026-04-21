#!/usr/bin/env node
/**
 * 与 App 一致：读链只使用标准 JSON-RPC POST 到 RPC_URL（等价于 GameConfig.BROKERCHAIN_RPC）。
 *
 * 不扫区块、不要交易 hash：
 * - 轮询工厂 `gameIdCounter()`，发现新 `gameId`
 * - `gameRooms(gameId)` 取 room 地址
 * - 读房间 `ecvrfRelay()`，全 0 则跳过（非 ECVRF 局）
 * - 轮询 `gameState()`，到 DEALING(=1) 后调用网关提交 `submitRandomWord`
 *
 * .env（与 run-relayer 共用即可）：
 *   RPC_URL              建议与 GameConfig.BROKERCHAIN_RPC 相同（部分节点裸 eth_call 无 result）
 *   READ_FALLBACK_RPC_URL 可选：备用只读节点
 *   GAME_FACTORY_ADDRESS 与 GameConfig.GAME_FACTORY_ADDRESS 相同
 *   ECVRF_RELAY_ADDRESS
 *   RELAYER_PRIVATE_KEY / VRF_SECRET_KEY
 *   GATEWAY_BASE_URL=https://dash.broker-chain.com:443
 *   当 RPC 读失败时，会自动使用网关「签名 eth_call」（与 NFTQueryUtil / HTTPUtil 一致）
 *
 * Usage:
 *   node auto-relayer-factory.js
 */
require("dotenv").config({ path: require("path").join(__dirname, ".env") });

const crypto = require("crypto");
const elliptic = require("elliptic");
const { AbiCoder, Interface, getAddress, Wallet } = require("ethers");
const { prove, proofToHash } = require("@roamin/ecvrf");

const RPC_URL = process.env.RPC_URL;
const RELAYER_PRIVATE_KEY = process.env.RELAYER_PRIVATE_KEY;
const VRF_SECRET_KEY = process.env.VRF_SECRET_KEY;
const ECVRF_RELAY_ADDRESS = process.env.ECVRF_RELAY_ADDRESS;
const GAME_FACTORY_ADDRESS = process.env.GAME_FACTORY_ADDRESS;
const GATEWAY_BASE_URL = (process.env.GATEWAY_BASE_URL || "https://dash.broker-chain.com:443").replace(/\/+$/, "");
const READ_FALLBACK_RPC_URL = (process.env.READ_FALLBACK_RPC_URL || "").trim();
const POLL_MS = Number(process.env.AUTO_RELAYER_POLL_MS || "3000");

if (!RPC_URL) throw new Error("Missing RPC_URL（请与 GameConfig.BROKERCHAIN_RPC 一致）");
if (!RELAYER_PRIVATE_KEY?.startsWith("0x")) throw new Error("Missing RELAYER_PRIVATE_KEY");
if (!VRF_SECRET_KEY?.startsWith("0x")) throw new Error("Missing VRF_SECRET_KEY");
if (!ECVRF_RELAY_ADDRESS?.startsWith("0x")) throw new Error("Missing ECVRF_RELAY_ADDRESS");
if (!GAME_FACTORY_ADDRESS?.startsWith("0x")) throw new Error("Missing GAME_FACTORY_ADDRESS");
if (!Number.isFinite(POLL_MS) || POLL_MS < 1000) throw new Error("Invalid AUTO_RELAYER_POLL_MS");

const DEALING = 1;
const ADDR_ZERO = "0x0000000000000000000000000000000000000000";

/** POST JSON-RPC 到任意 endpoint */
async function rpcAt(url, method, params) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const text = await res.text();
  let obj = null;
  try {
    obj = JSON.parse(text);
  } catch (_) {}
  if (!res.ok) throw new Error(`RPC ${method} http ${res.status}: ${text.slice(0, 120)}`);
  if (obj?.error) throw new Error(`RPC ${method}: ${JSON.stringify(obj.error)}`);
  if (obj && !Object.prototype.hasOwnProperty.call(obj, "result")) {
    throw new Error(`RPC ${method} missing result: ${text.slice(0, 120)}`);
  }
  return obj.result;
}

/**
 * 与 GameBattle / GameRoomWaitActivity 一致：eth_call 带 from（部分节点 from 为空会异常）。
 */
async function tryJsonRpcEthCall(readUrl, fromAddr, to, data) {
  const params = [{ from: fromAddr, to: getAddress(to), data, value: "0x0" }, "latest"];
  return rpcAt(readUrl, "eth_call", params);
}

async function postGateway(path, body) {
  const url = `${GATEWAY_BASE_URL.replace(/\/+$/, "")}/${path}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let obj = null;
  try {
    obj = JSON.parse(text);
  } catch (_) {}
  return { status: res.status, text, obj };
}

function sha256HexFromUtf8(s) {
  return crypto.createHash("sha256").update(Buffer.from(s, "utf8")).digest("hex");
}

/**
 * 与 NFTQueryUtil / HTTPUtil.doPost("eth_call") 一致：
 * thedata = to + data + "0x0" + uuid，再 SHA256(utf8)、ECDSA，JSON 字段 PublicKey/RandomStr/To/data/value/Sign1/Sign2
 */
async function gatewaySignedEthCall(to, data, relayerKey, relayerPub) {
  const uuid = crypto.randomUUID();
  const value = "0x0";
  const toNorm = getAddress(to);
  const thedata = `${toNorm}${data}${value}${uuid}`;
  const digestHex = sha256HexFromUtf8(thedata);
  const sig = relayerKey.sign(digestHex, { canonical: false });
  const req = {
    PublicKey: relayerPub,
    RandomStr: uuid,
    To: toNorm,
    data,
    value,
    Sign1: sig.r.toString(16),
    Sign2: sig.s.toString(16),
  };
  const gw = await postGateway("eth_call", req);
  const out = gw.obj?.result;
  if (typeof out === "string" && out.startsWith("0x")) return out;
  throw new Error(`gateway eth_call bad response: ${gw.text.slice(0, 180)}`);
}

async function readContract(readUrls, fromAddr, to, data, gatewayEthCallFn) {
  let lastErr = null;
  for (const u of readUrls) {
    if (!u) continue;
    try {
      const r = await tryJsonRpcEthCall(u, fromAddr, to, data);
      if (r != null && r !== undefined && typeof r === "string" && r.startsWith("0x") && r.length > 2) return r;
    } catch (e) {
      lastErr = e;
    }
  }
  try {
    return await gatewayEthCallFn();
  } catch (e) {
    const msg = lastErr?.message || "";
    throw new Error(`readContract failed; lastJsonRpc=${msg}; gateway=${e?.message || e}`);
  }
}

function normalizeProofToWitnet81(proofHex) {
  const p = proofHex.startsWith("0x") ? proofHex : "0x" + proofHex;
  if ((p.length - 2) / 2 !== 81) throw new Error("proof len != 81");
  return p;
}

async function main() {
  const EC = new elliptic.ec("secp256k1");
  const relayerPriv = RELAYER_PRIVATE_KEY.replace(/^0x/, "");
  const relayerKey = EC.keyFromPrivate(relayerPriv, "hex");
  const relayerPub = relayerKey.getPublic(false, "hex");
  const relayerFromAddr = getAddress(new Wallet(RELAYER_PRIVATE_KEY).address);
  const vrfKey = EC.keyFromPrivate(VRF_SECRET_KEY.replace(/^0x/, ""), "hex");

  const factoryIface = new Interface([
    "function gameIdCounter() view returns (uint256)",
    "function gameRooms(uint256) view returns (address)",
  ]);
  const roomIface = new Interface([
    "function gameState() view returns (uint8)",
    "function ecvrfRelay() view returns (address)",
  ]);
  const relayIface = new Interface([
    "function submitRandomWord(address room, bytes alpha, bytes proof, uint256 randomWord) external",
  ]);

  const coder = AbiCoder.defaultAbiCoder();
  const factory = getAddress(GAME_FACTORY_ADDRESS);
  const relayAddr = getAddress(ECVRF_RELAY_ADDRESS);

  const readUrls = [RPC_URL, READ_FALLBACK_RPC_URL].filter(Boolean);

  console.log("[auto] read RPC(s) =", readUrls.join(" | "));
  console.log("[auto] eth_call from =", relayerFromAddr, "（与 App 一样带 from）");
  console.log("[auto] factory =", factory);
  console.log("[auto] gateway =", GATEWAY_BASE_URL);

  const doRead = (to, data) =>
    readContract(readUrls, relayerFromAddr, to, data, () => gatewaySignedEthCall(to, data, relayerKey, relayerPub));

  let lastCounter = 0n;
  /** gameId -> { room, submitted } */
  const tracking = new Map();

  // 初始化：当前链上 counter，只处理「之后」新开局
  try {
    const data = factoryIface.encodeFunctionData("gameIdCounter", []);
    const raw = await doRead(factory, data);
    if (!raw || raw === "0x") throw new Error("empty gameIdCounter");
    lastCounter = BigInt(raw);
    console.log("[auto] gameIdCounter =", lastCounter.toString(), "(已同步：只处理之后新开的局)");
  } catch (e) {
    console.error("[auto] FATAL read failed: JSON-RPC 无 result 时会走网关签名 eth_call；若仍失败请检查 RELAYER_PRIVATE_KEY 与 GATEWAY_BASE_URL");
    console.error(e?.message || e);
    process.exit(1);
  }

  async function submitOnce(gameId, room) {
    const alphaHex = coder.encode(["uint256", "address"], [gameId, room]);
    const proof = prove(vrfKey.getPrivate(), alphaHex.replace(/^0x/, ""));
    const proof81 = normalizeProofToWitnet81(proof);
    const rw = BigInt("0x" + proofToHash(proof81.replace(/^0x/, "")));
    const calldata = relayIface.encodeFunctionData("submitRandomWord", [room, alphaHex, proof81, rw]);
    const value = "0x0";
    const gas = "0x800000";
    const randomStr = crypto.randomUUID();
    const signPayload = `${relayAddr}${calldata}${value}${gas}${randomStr}`;
    const digestHex = sha256HexFromUtf8(signPayload);
    const sig = relayerKey.sign(digestHex, { canonical: false });
    const req = {
      PublicKey: relayerPub,
      RandomStr: randomStr,
      To: relayAddr,
      data: calldata,
      value,
      Gas: gas,
      Sign1: sig.r.toString(16),
      Sign2: sig.s.toString(16),
    };
    const gw = await postGateway("eth_sendTransaction", req);
    const h = gw.obj?.result;
    console.log("[auto] submitRandomWord gameId=%s room=%s tx=%s", gameId.toString(), room, h || gw.text.slice(0, 80));
    return !!h;
  }

  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      const rawC = await doRead(factory, factoryIface.encodeFunctionData("gameIdCounter", []));
      const counter = BigInt(rawC);

      if (counter > lastCounter) {
        // 新创建了 gameId 在 [lastCounter, counter - 1] —— Solidity: gameId = gameIdCounter++ 所以新建局 id 为 lastCounter ... counter-1
        for (let gid = lastCounter; gid < counter; gid++) {
          const rr = await doRead(factory, factoryIface.encodeFunctionData("gameRooms", [gid]));
          const room = getAddress("0x" + rr.slice(-40));
          if (room === getAddress(ADDR_ZERO)) continue;

          const eraw = await doRead(room, roomIface.encodeFunctionData("ecvrfRelay", []));
          const er = getAddress("0x" + eraw.slice(-40));
          const relayCfg = getAddress(ECVRF_RELAY_ADDRESS);
          if (er === getAddress(ADDR_ZERO)) {
            console.log("[auto] gameId=%s room=%s ecvrf=0 skip", gid.toString(), room);
            continue;
          }
          if (er.toLowerCase() !== relayCfg.toLowerCase()) {
            console.log("[auto] gameId=%s room ecvrf=%s (expected %s) skip", gid.toString(), er, relayCfg);
            continue;
          }
          tracking.set(gid.toString(), { room, submitted: false });
          console.log("[auto] track gameId=%s room=%s (wait DEALING)", gid.toString(), room);
        }
        lastCounter = counter;
      }

      for (const [gidStr, rec] of tracking) {
        if (rec.submitted) continue;
        const gid = BigInt(gidStr);
        const room = rec.room;
        const stRaw = await doRead(room, roomIface.encodeFunctionData("gameState", []));
        const st = Number(BigInt(stRaw));
        if (st === DEALING) {
          console.log("[auto] DEALING detected gameId=%s -> submit", gidStr);
          const ok = await submitOnce(gid, room);
          if (ok) rec.submitted = true;
        }
      }
    } catch (e) {
      console.error("[auto] tick error:", e?.message || e);
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

main().catch((e) => {
  console.error(e?.message || e);
  process.exitCode = 1;
});
