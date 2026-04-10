const { expect } = require("chai");
const { ethers } = require("hardhat");

// witnet/vrf-solidity test/data.json — verify.valid[0]
const WITNET_VECTOR = {
  publicKeyX: "0x2c8c31fc9f990c6b55e3865a184a4ce50e09481f2eaeb3e60ec1cea13a6ae645",
  publicKeyY: "0x64b95e4fdb6948c0386e189b006a29f686769b011704275e4459822dc3328085",
  message: "0x73616d706c65", // "sample"
  pi: "0x031f4dbca087a1972d04a07a779b7df1caa99e0f5db2aa21f3aecc4f9e10e85d0814faa89697b482daa377fb6b4a8b0191a65d34a6d90a8a2461e5db9205d4cf0bb4b2c31b5ef6997a585a9f1a72517b6f",
  hash: "0x612065e309e937ef46c2ef04d5886b9c6efd2991ac484ec64a9b014366fc5d81",
};

describe("ECVRF", function () {
  it("Secp256k1Sha256TaiECVRFVerifier accepts Witnet test vector", async function () {
    const Verifier = await ethers.getContractFactory("Secp256k1Sha256TaiECVRFVerifier");
    const v = await Verifier.deploy(WITNET_VECTOR.publicKeyX, WITNET_VECTOR.publicKeyY);
    await v.waitForDeployment();
    const randomWord = BigInt(WITNET_VECTOR.hash);
    expect(
      await v.verify.staticCall(WITNET_VECTOR.message, WITNET_VECTOR.pi, randomWord)
    ).to.equal(true);
  });

  it("Secp256k1Sha256TaiECVRFVerifier rejects wrong randomWord", async function () {
    const Verifier = await ethers.getContractFactory("Secp256k1Sha256TaiECVRFVerifier");
    const v = await Verifier.deploy(WITNET_VECTOR.publicKeyX, WITNET_VECTOR.publicKeyY);
    await v.waitForDeployment();
    expect(
      await v.verify.staticCall(WITNET_VECTOR.message, WITNET_VECTOR.pi, 1n)
    ).to.equal(false);
  });

  it("ECVRFRelay + NaiveECVRFVerifier + MockGameRoom submits seed", async function () {
    const [relayer] = await ethers.getSigners();
    const Naive = await ethers.getContractFactory("NaiveECVRFVerifier");
    const naive = await Naive.deploy();
    await naive.waitForDeployment();
    const Relay = await ethers.getContractFactory("ECVRFRelay");
    const relay = await Relay.deploy(relayer.address, await naive.getAddress());
    await relay.waitForDeployment();
    const Mock = await ethers.getContractFactory("MockGameRoomEcvrf");
    const room = await Mock.deploy(7n, await relay.getAddress());
    await room.waitForDeployment();
    const alpha = ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "address"], [7n, await room.getAddress()]);
    const proof = ethers.hexlify(new Uint8Array(81).fill(1));
    const rw = 12345n;
    await relay.connect(relayer).submitRandomWord(await room.getAddress(), alpha, proof, rw);
    expect(await room.lastSeed()).to.equal(rw);
    expect(await room.dealing()).to.equal(false);
  });

  it("ECVRFRelay reverts when alpha mismatches gameId/room", async function () {
    const [relayer] = await ethers.getSigners();
    const naive = await (await ethers.getContractFactory("NaiveECVRFVerifier")).deploy();
    await naive.waitForDeployment();
    const relay = await (
      await ethers.getContractFactory("ECVRFRelay")
    ).deploy(relayer.address, await naive.getAddress());
    await relay.waitForDeployment();
    const room = await (await ethers.getContractFactory("MockGameRoomEcvrf")).deploy(7n, await relay.getAddress());
    await room.waitForDeployment();
    const badAlpha = ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "address"], [8n, await room.getAddress()]);
    const proof = ethers.hexlify(new Uint8Array(81).fill(3));
    await expect(
      relay.connect(relayer).submitRandomWord(await room.getAddress(), badAlpha, proof, 99n)
    ).to.be.revertedWith("!alpha");
  });
});
