import { useEffect, useState } from 'react';
import { ethers } from 'ethers';
import config from './config.json';
import OracleABI from './AdvancedSecureOracle.json';
import TokenABI from './OracleToken.json';
import VulnABI from './VulnerableOracle.json';
import './index.css';

const RPC_URL = config.rpcUrl ?? 'http://127.0.0.1:8545';
const TRUE_PRICE = config.honestPrice ?? 60000;
const MALICIOUS_PRICE = config.maliciousPrice ?? 1;
const DEFAULT_QUORUM = config.requiredSignatures ?? 3;
const SECRET_SALT = 999;
const LOG_LIMIT = 12;

function appendLogEntry(setLogs, message) {
  const timestamp = new Date().toLocaleTimeString();
  console.log(`[${timestamp}] ${message}`);
  setLogs((current) => [
    { id: `${Date.now()}-${Math.random()}`, timestamp, message },
    ...current,
  ].slice(0, LOG_LIMIT));
}

function formatUsd(value) {
  return `$${Number(value).toLocaleString()}`;
}

function shortenAddress(address) {
  if (!address) {
    return 'Unknown address';
  }

  return `${address.slice(0, 10)}...${address.slice(-4)}`;
}

function extractError(error) {
  return error?.reason || error?.shortMessage || error?.message || 'Unknown error';
}

async function getOwnerSigner(provider) {
  const accounts = await provider.listAccounts();
  if (accounts.length === 0) {
    throw new Error('No accounts available in the local Anvil node.');
  }

  const firstAccount = typeof accounts[0] === 'string' ? accounts[0] : accounts[0].address;
  return provider.getSigner(firstAccount);
}

async function syncVulnerableState(contract, setVulnState) {
  const price = await contract.latestPrice();
  setVulnState({ latestPrice: Number(price) });
}

async function syncAdvancedState(oracleContract, tokenContract, setOracleState, setNodes) {
  const [
    currentRound,
    currentPhase,
    commitsThisRound,
    revealsThisRound,
    latestPrice,
    activeNodes,
    quorum,
  ] = await oracleContract.getRoundState();

  setOracleState({
    round: Number(currentRound),
    phase: Number(currentPhase) === 0 ? 'Commit' : 'Reveal',
    commits: Number(commitsThisRound),
    reveals: Number(revealsThisRound),
    latestPrice: Number(latestPrice),
    activeNodes: Number(activeNodes),
    quorum: Number(quorum),
  });

  const updatedNodes = await Promise.all(
    config.nodes.map(async (nodeConfig) => {
      const [stake, liquid, commitment, hasRevealed, challenge] = await Promise.all([
        oracleContract.stakes(nodeConfig.address),
        tokenContract.balanceOf(nodeConfig.address),
        oracleContract.commitments(currentRound, nodeConfig.address),
        oracleContract.hasRevealed(currentRound, nodeConfig.address),
        oracleContract.nodeChallenges(nodeConfig.address),
      ]);

      return {
        ...nodeConfig,
        stake: ethers.formatUnits(stake, 18),
        liquid: ethers.formatUnits(liquid, 18),
        hasCommitted: commitment !== ethers.ZeroHash,
        hasRevealed,
        isChallenged: Boolean(challenge.isChallenged),
      };
    }),
  );

  setNodes(updatedNodes);
}

function App() {
  const [provider, setProvider] = useState(null);
  const [oracle, setOracle] = useState(null);
  const [token, setToken] = useState(null);
  const [vulnOracle, setVulnOracle] = useState(null);
  const [nodes, setNodes] = useState([]);
  const [logs, setLogs] = useState([]);
  const [viewMode, setViewMode] = useState('advanced');
  const [pendingAction, setPendingAction] = useState('');
  const [connectionStatus, setConnectionStatus] = useState('Connecting to local Anvil node...');
  const [oracleState, setOracleState] = useState({
    round: 1,
    phase: 'Commit',
    commits: 0,
    reveals: 0,
    latestPrice: 0,
    activeNodes: config.nodes.length,
    quorum: DEFAULT_QUORUM,
  });
  const [vulnState, setVulnState] = useState({ latestPrice: 0 });

  useEffect(() => {
    let isCancelled = false;

    const init = async () => {
      try {
        const rpcProvider = new ethers.JsonRpcProvider(RPC_URL);
        const nextOracle = new ethers.Contract(config.oracleAddress, OracleABI.abi, rpcProvider);
        const nextToken = new ethers.Contract(config.tokenAddress, TokenABI.abi, rpcProvider);
        const nextVulnOracle = new ethers.Contract(config.vulnOracleAddress, VulnABI.abi, rpcProvider);

        await Promise.all([
          syncAdvancedState(nextOracle, nextToken, setOracleState, setNodes),
          syncVulnerableState(nextVulnOracle, setVulnState),
        ]);

        if (isCancelled) {
          return;
        }

        setProvider(rpcProvider);
        setOracle(nextOracle);
        setToken(nextToken);
        setVulnOracle(nextVulnOracle);
        setConnectionStatus('Connected to local Anvil node.');
        appendLogEntry(setLogs, 'Connected to the local blockchain and loaded the latest deployment.');
      } catch (error) {
        if (isCancelled) {
          return;
        }

        setConnectionStatus('Connection failed. Start Anvil and redeploy the contracts.');
        appendLogEntry(setLogs, 'Failed to connect to the local blockchain. Start Anvil and redeploy the contracts.');
        console.error(error);
      }
    };

    init();
    return () => {
      isCancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!oracle || !token || !vulnOracle) {
      return undefined;
    }

    const handlePhaseTransition = (round, phase, activeNodeCount) => {
      const phaseLabel = Number(phase) === 0 ? 'Commit' : 'Reveal';
      appendLogEntry(
        setLogs,
        `Round ${round} moved into ${phaseLabel} with ${activeNodeCount} active nodes.`,
      );
      void syncAdvancedState(oracle, token, setOracleState, setNodes);
    };

    const handleRoundFinalized = (price, round) => {
      appendLogEntry(setLogs, `Round ${round} finalized. Official median price: ${formatUsd(price)}.`);
      void syncAdvancedState(oracle, token, setOracleState, setNodes);
    };

    const handleNodeChallenged = (node, reason, amount) => {
      appendLogEntry(
        setLogs,
        `Node ${shortenAddress(node)} was challenged for ${reason}. Slash at risk: ${ethers.formatUnits(amount, 18)} OST.`,
      );
      void syncAdvancedState(oracle, token, setOracleState, setNodes);
    };

    const handleNodeSlashed = (node, amount) => {
      appendLogEntry(
        setLogs,
        `Node ${shortenAddress(node)} was slashed for ${ethers.formatUnits(amount, 18)} OST.`,
      );
      void syncAdvancedState(oracle, token, setOracleState, setNodes);
    };

    const handleRewardDistributed = (total, count) => {
      appendLogEntry(
        setLogs,
        `${ethers.formatUnits(total, 18)} OST was redistributed across ${count} honest nodes.`,
      );
      void syncAdvancedState(oracle, token, setOracleState, setNodes);
    };

    const handleRoundReset = (round) => {
      appendLogEntry(setLogs, `Round ${round} was reset after a timeout condition.`);
      void syncAdvancedState(oracle, token, setOracleState, setNodes);
    };

    const handleVulnerablePriceUpdate = (price) => {
      appendLogEntry(setLogs, `VulnerableOracle accepted a new price: ${formatUsd(price)}.`);
      void syncVulnerableState(vulnOracle, setVulnState);
    };

    oracle.on('PhaseTransition', handlePhaseTransition);
    oracle.on('RoundFinalized', handleRoundFinalized);
    oracle.on('NodeChallenged', handleNodeChallenged);
    oracle.on('NodeSlashed', handleNodeSlashed);
    oracle.on('RewardDistributed', handleRewardDistributed);
    oracle.on('RoundReset', handleRoundReset);
    vulnOracle.on('PriceUpdated', handleVulnerablePriceUpdate);

    return () => {
      oracle.off('PhaseTransition', handlePhaseTransition);
      oracle.off('RoundFinalized', handleRoundFinalized);
      oracle.off('NodeChallenged', handleNodeChallenged);
      oracle.off('NodeSlashed', handleNodeSlashed);
      oracle.off('RewardDistributed', handleRewardDistributed);
      oracle.off('RoundReset', handleRoundReset);
      vulnOracle.off('PriceUpdated', handleVulnerablePriceUpdate);
    };
  }, [oracle, token, vulnOracle]);

  const refreshAllState = async (
    nextOracle = oracle,
    nextToken = token,
    nextVulnerable = vulnOracle,
  ) => {
    if (nextOracle && nextToken) {
      await syncAdvancedState(nextOracle, nextToken, setOracleState, setNodes);
    }

    if (nextVulnerable) {
      await syncVulnerableState(nextVulnerable, setVulnState);
    }
  };

  const withPendingAction = async (label, action) => {
    if (pendingAction) {
      return;
    }

    setPendingAction(label);

    try {
      await action();
    } catch (error) {
      appendLogEntry(setLogs, `${label} failed: ${extractError(error)}`);
      console.error(error);
    } finally {
      setPendingAction('');
    }
  };

  // ---- Advanced Oracle Actions ----
  const executeAsNode = async (nodeConfig, action, ...args) => {
    if (!provider || !oracle) {
      return;
    }

    const signer = await provider.getSigner(nodeConfig.address);
    const oracleWithSigner = oracle.connect(signer);

    const tx = await oracleWithSigner[action](...args);
    await tx.wait();
    appendLogEntry(setLogs, `${nodeConfig.name} executed ${action} successfully.`);
  };

  const simulateHonestCommits = () => withPendingAction('Submitting honest commits', async () => {
    const commitment = ethers.solidityPackedKeccak256(['uint256', 'uint256'], [TRUE_PRICE, SECRET_SALT]);

    for (const node of nodes.filter((currentNode) => !currentNode.isEclipsed && !currentNode.isChallenged)) {
      if (!node.hasCommitted) {
        await executeAsNode(node, 'commitPrice', commitment);
      }
    }

    await refreshAllState();
  });

  const simulateEclipsedCommits = () => withPendingAction('Submitting eclipsed commits', async () => {
    const commitment = ethers.solidityPackedKeccak256(['uint256', 'uint256'], [MALICIOUS_PRICE, SECRET_SALT]);

    for (const node of nodes.filter((currentNode) => currentNode.isEclipsed && !currentNode.isChallenged)) {
      if (!node.hasCommitted) {
        await executeAsNode(node, 'commitPrice', commitment);
      }
    }

    await refreshAllState();
  });

  const simulateHonestReveals = () => withPendingAction('Revealing honest prices', async () => {
    for (const node of nodes.filter((currentNode) => !currentNode.isEclipsed && !currentNode.isChallenged)) {
      if (node.hasCommitted && !node.hasRevealed) {
        await executeAsNode(node, 'revealPrice', TRUE_PRICE, SECRET_SALT);
      }
    }

    await refreshAllState();
  });

  const simulateEclipsedReveals = () => withPendingAction('Revealing eclipsed prices', async () => {
    for (const node of nodes.filter((currentNode) => currentNode.isEclipsed && !currentNode.isChallenged)) {
      if (node.hasCommitted && !node.hasRevealed) {
        await executeAsNode(node, 'revealPrice', MALICIOUS_PRICE, SECRET_SALT);
      }
    }

    await refreshAllState();
  });

  const triggerCommitTimeout = async () => {
    await withPendingAction('Forcing commit timeout', async () => {
      if (!provider || !oracle) {
        return;
      }

      await provider.send("evm_increaseTime", [360]);
      await provider.send("evm_mine", []);
      appendLogEntry(setLogs, 'Fast-forwarded the local chain by 6 minutes.');
      const ownerSigner = await getOwnerSigner(provider);
      const tx = await oracle.connect(ownerSigner).forceCommitTimeout();
      await tx.wait();
      appendLogEntry(setLogs, 'forceCommitTimeout() executed successfully.');
      await refreshAllState();
    });
  };

  const triggerRevealTimeout = async () => {
    await withPendingAction('Forcing reveal timeout', async () => {
      if (!provider || !oracle) {
        return;
      }

      await provider.send("evm_increaseTime", [360]);
      await provider.send("evm_mine", []);
      appendLogEntry(setLogs, 'Fast-forwarded the local chain by 6 minutes.');
      const ownerSigner = await getOwnerSigner(provider);
      const tx = await oracle.connect(ownerSigner).forceTimeout();
      await tx.wait();
      appendLogEntry(setLogs, 'forceTimeout() executed successfully.');
      await refreshAllState();
    });
  };

  const executeSlashing = async () => {
    await withPendingAction('Executing slashing', async () => {
      if (!provider || !oracle) {
        return;
      }

      await provider.send("evm_increaseTime", [86401]); // 1 day + 1 second
      await provider.send("evm_mine", []);
      appendLogEntry(setLogs, 'Fast-forwarded the local chain by 24 hours.');
      const ownerSigner = await getOwnerSigner(provider);
      for (const node of nodes) {
        if (node.isChallenged) {
          const tx = await oracle.connect(ownerSigner).executeSlashing(node.address);
          await tx.wait();
        }
      }
      appendLogEntry(setLogs, 'Slashing completed. Tokens were burned and redistributed.');
      await refreshAllState();
    });
  };

  // ---- Vulnerable Oracle Actions ----
  const executeEclipseAttack = async () => {
    await withPendingAction('Executing eclipse attack', async () => {
      if (!provider || !vulnOracle) {
        return;
      }

      const eclipsedNode = config.nodes.find(n => n.isEclipsed);
      const signer = await provider.getSigner(eclipsedNode.address);
      appendLogEntry(setLogs, `Eclipse attack initiated. Eclipsed node is submitting ${formatUsd(MALICIOUS_PRICE)}.`);
      const tx = await vulnOracle.connect(signer).updatePrice(MALICIOUS_PRICE);
      await tx.wait();
      appendLogEntry(setLogs, `Attack succeeded. VulnerableOracle price moved to ${formatUsd(MALICIOUS_PRICE)} with no defense.`);
      await refreshAllState();
    });
  };

  const restoreHonestPrice = async () => {
    await withPendingAction('Restoring honest vulnerable price', async () => {
      if (!provider || !vulnOracle) {
        return;
      }

      const eclipsedNode = config.nodes.find(n => n.isEclipsed);
      const signer = await provider.getSigner(eclipsedNode.address);
      const tx = await vulnOracle.connect(signer).updatePrice(TRUE_PRICE);
      await tx.wait();
      appendLogEntry(setLogs, `VulnerableOracle price restored to ${formatUsd(TRUE_PRICE)}.`);
      await refreshAllState();
    });
  };

  // ---- Reset ----
  const resetSimulation = async () => {
    await withPendingAction('Resetting simulation', async () => {
      if (!provider || !oracle || !vulnOracle) {
        return;
      }

      appendLogEntry(setLogs, 'Factory reset started. Redeploying contracts...');
      const ownerSigner = await getOwnerSigner(provider);

      // 1. Deploy new VulnerableOracle
      const vulnBytecode = VulnABI.bytecode?.object || VulnABI.bytecode;
      const VulnFactory = new ethers.ContractFactory(VulnABI.abi, vulnBytecode, ownerSigner);
      const eclipsedAddr = config.nodes.find(n => n.isEclipsed).address;
      const newVuln = await VulnFactory.deploy(eclipsedAddr);
      await newVuln.waitForDeployment();
      const eclipsedSigner = await provider.getSigner(eclipsedAddr);
      await (await newVuln.connect(eclipsedSigner).updatePrice(TRUE_PRICE)).wait();
      config.vulnOracleAddress = await newVuln.getAddress();

      // 2. Deploy Token
      const tokenBytecode = TokenABI.bytecode?.object || TokenABI.bytecode;
      const TokenFactory = new ethers.ContractFactory(TokenABI.abi, tokenBytecode, ownerSigner);
      const newToken = await TokenFactory.deploy(100000);
      await newToken.waitForDeployment();
      const tokenAddress = await newToken.getAddress();

      // 3. Deploy Advanced Oracle
      const oracleBytecode = OracleABI.bytecode?.object || OracleABI.bytecode;
      const OracleFactory = new ethers.ContractFactory(OracleABI.abi, oracleBytecode, ownerSigner);
      const newOracle = await OracleFactory.deploy(
        tokenAddress,
        config.nodes.map((node) => node.address),
        config.requiredSignatures ?? DEFAULT_QUORUM,
      );
      await newOracle.waitForDeployment();
      const oracleAddress = await newOracle.getAddress();
      
      // Set the newly deployed oracle as the authorized burner for the token
      await (await newToken.connect(ownerSigner).setOracleAddress(oracleAddress)).wait();
      
      appendLogEntry(setLogs, 'New contracts deployed. Re-staking tokens for all nodes.');

      // 4. Stake
      const stakeAmount = ethers.parseUnits("1000", 18);
      for (const nodeConfig of config.nodes) {
        const nodeSigner = await provider.getSigner(nodeConfig.address);
        await (await newToken.connect(ownerSigner).transfer(nodeConfig.address, stakeAmount)).wait();
        await (await newToken.connect(nodeSigner).approve(oracleAddress, stakeAmount)).wait();
        await (await newOracle.connect(nodeSigner).stake()).wait();
      }

      config.oracleAddress = oracleAddress;
      config.tokenAddress = tokenAddress;
      setOracle(newOracle);
      setToken(newToken);
      setVulnOracle(newVuln);
      await refreshAllState(newOracle, newToken, newVuln);
      appendLogEntry(setLogs, 'Factory reset complete. The simulation is ready for another round.');
    });
  };

  const isBusy = pendingAction.length > 0;
  const nodeCount = config.nodes.length;
  const primaryEclipsedNode = config.nodes.find((node) => node.isEclipsed);

  return (
    <div className="dashboard-container">
      <header className="header">
        <h1>Cryptoeconomic Oracle Dashboard</h1>
        <p>Real-time simulation of Eclipse Attacks &amp; Cryptoeconomic Defenses</p>
        <div className={`status-pill ${connectionStatus.startsWith('Connected') ? 'is-connected' : 'is-warning'}`}>
          {connectionStatus}
        </div>
      </header>

      {/* Mode Toggle */}
      <div className="mode-toggle">
        <button
          className="btn"
          onClick={() => setViewMode('vulnerable')}
          disabled={isBusy}
          style={{
            borderRadius: '0.5rem 0 0 0.5rem',
            backgroundColor: viewMode === 'vulnerable' ? 'var(--danger)' : 'var(--border)',
            fontWeight: viewMode === 'vulnerable' ? 'bold' : 'normal',
            borderRight: '1px solid var(--bg-color)'
          }}
        >
          ⚠️ Vulnerable Oracle
        </button>
        <button
          className="btn"
          onClick={() => setViewMode('advanced')}
          disabled={isBusy}
          style={{
            borderRadius: '0 0.5rem 0.5rem 0',
            backgroundColor: viewMode === 'advanced' ? 'var(--accent)' : 'var(--border)',
            fontWeight: viewMode === 'advanced' ? 'bold' : 'normal',
          }}
        >
          🛡️ Advanced Oracle
        </button>
      </div>

      {/* ===== VULNERABLE VIEW ===== */}
      {viewMode === 'vulnerable' && (
        <>
          <div className="stats-grid">
            <div className="stat-card" style={{ borderColor: 'var(--danger)' }}>
              <div className="stat-title">Architecture</div>
              <div className="stat-value" style={{ fontSize: '1.2rem', color: 'var(--danger)' }}>Single Trusted Node</div>
            </div>
            <div className="stat-card" style={{ borderColor: vulnState.latestPrice === MALICIOUS_PRICE ? 'var(--danger)' : 'var(--border)' }}>
              <div className="stat-title">Official Oracle Price</div>
              <div className="stat-value" style={{ color: vulnState.latestPrice === MALICIOUS_PRICE ? 'var(--danger)' : 'var(--success)' }}>
                ${vulnState.latestPrice.toLocaleString()}
              </div>
            </div>
            <div className="stat-card">
              <div className="stat-title">Eclipse Defense</div>
              <div className="stat-value" style={{ fontSize: '1.2rem', color: 'var(--danger)' }}>NONE ✗</div>
            </div>
          </div>

          <div className="nodes-grid" style={{ gridTemplateColumns: '1fr' }}>
            <div className="node-card eclipsed">
              <span className="node-badge badge-eclipsed">Single Point of Failure</span>
              <h3 className="node-name">Sole Authorized Node (Eclipsed)</h3>
              <div className="node-address">{shortenAddress(primaryEclipsedNode?.address)}</div>
              <div className="node-status">
                <span className="status-label">Current Price Report:</span>
                <span className="status-value" style={{ color: vulnState.latestPrice === MALICIOUS_PRICE ? 'var(--danger)' : 'var(--success)' }}>
                  ${vulnState.latestPrice.toLocaleString()}
                </span>
              </div>
              <div className="node-status">
                <span className="status-label">Staked Collateral:</span>
                <span className="status-value" style={{ color: 'var(--danger)' }}>$0 (No Stake Required)</span>
              </div>
              <div className="node-status">
                <span className="status-label">Slashing Mechanism:</span>
                <span className="status-value" style={{ color: 'var(--danger)' }}>None — Attacker Faces Zero Risk</span>
              </div>
            </div>
          </div>

            <div className="controls">
              <h2>Attack Simulation</h2>
              <div className="btn-group">
                <button className="btn btn-danger" onClick={executeEclipseAttack} disabled={isBusy || !provider || !vulnOracle}>
                  🔴 Execute Eclipse Attack (Submit $1)
                </button>
                <button className="btn btn-primary" onClick={restoreHonestPrice} disabled={isBusy || !provider || !vulnOracle}>
                  ✅ Restore Honest Price ({formatUsd(TRUE_PRICE)})
                </button>
              </div>
              <p style={{ color: 'var(--text-muted)', fontSize: '0.9rem', marginTop: '1rem' }}>
                Notice: The attacker submits manipulated data with zero resistance. There is no staking, no median consensus, and no financial penalty. Switch to the Advanced Oracle to see the solution.
              </p>
            </div>
          </>
        )}

      {/* ===== ADVANCED VIEW ===== */}
      {viewMode === 'advanced' && (
        <>
          <div className="stats-grid">
            <div className="stat-card">
              <div className="stat-title">Current Round</div>
              <div className="stat-value">{oracleState.round}</div>
            </div>
            <div className="stat-card">
              <div className="stat-title">Official Median Price</div>
              <div className="stat-value" style={{ color: oracleState.latestPrice === TRUE_PRICE ? 'var(--success)' : (oracleState.latestPrice === 0 ? 'var(--text-muted)' : 'var(--danger)') }}>
                {formatUsd(oracleState.latestPrice)}
              </div>
            </div>
            <div className="stat-card">
              <div className="stat-title">Quorum Model</div>
              <div className="stat-value" style={{ fontSize: '1.5rem' }}>
                {oracleState.quorum} / {nodeCount}
              </div>
              <div className="stat-title" style={{ marginTop: '0.5rem' }}>
                Active Nodes: {oracleState.activeNodes}
              </div>
            </div>
            <div className="stat-card">
              <div className="stat-title">Phase Status</div>
              <div className="stat-value">{oracleState.phase}</div>
              <div className="stat-title" style={{ marginTop: '0.5rem' }}>
                {oracleState.phase === 'Commit'
                  ? `${oracleState.commits} / ${oracleState.activeNodes} commits`
                  : `${oracleState.reveals} / ${oracleState.commits} reveals`}
              </div>
            </div>
          </div>

          <div className="architecture-note">
            <strong>Architecture:</strong> Stake-backed 3-of-5 committee, commit-reveal submissions, MAD anomaly detection, delayed slashing, and reward redistribution.
          </div>

          <div className="nodes-grid">
            {nodes.map((node) => (
              <div key={node.address} className={`node-card ${node.isEclipsed ? 'eclipsed' : ''}`} style={node.isChallenged ? { borderColor: 'var(--danger)', opacity: 0.8 } : {}}>
                <span className={`node-badge ${node.isChallenged ? 'badge-danger' : (node.isEclipsed ? 'badge-eclipsed' : 'badge-honest')}`} style={node.isChallenged ? { backgroundColor: 'var(--danger)' } : {}}>
                  {node.isChallenged ? 'SUSPENDED / CHALLENGED' : (node.isEclipsed ? 'Eclipsed (Attacker)' : 'Honest Node')}
                </span>
                <h3 className="node-name" style={node.isChallenged ? { color: 'var(--danger)' } : {}}>{node.name}</h3>
                <div className="node-address">{shortenAddress(node.address)}</div>
                <div className="node-status">
                  <span className="status-label">Liquid / Staked:</span>
                  <span className="status-value" style={{ color: node.stake === "0.0" ? 'var(--danger)' : 'var(--text-main)' }}>
                    {Number.parseFloat(node.liquid).toFixed(2)} / {Number.parseFloat(node.stake).toFixed(2)} OST
                  </span>
                </div>
                {!node.isChallenged ? (
                  <>
                    <div className="node-status">
                      <span className="status-label">Commitment:</span>
                      <span className="status-value" style={{ color: node.hasCommitted ? 'var(--success)' : 'var(--text-muted)' }}>
                        {node.hasCommitted ? 'LOCKED' : 'WAITING'}
                      </span>
                    </div>
                    <div className="node-status">
                      <span className="status-label">Reveal:</span>
                      <span className="status-value" style={{ color: node.hasRevealed ? 'var(--success)' : 'var(--text-muted)' }}>
                        {node.hasRevealed ? 'REVEALED' : 'WAITING'}
                      </span>
                    </div>
                  </>
                ) : (
                  <div className="node-status node-status-centered">
                    <strong>Awaiting Slash Execution</strong>
                  </div>
                )}
              </div>
            ))}
          </div>

          <div className="controls">
            <h2>Simulation Controls</h2>
            <div className="btn-group">
              <button className="btn btn-primary" onClick={simulateHonestCommits} disabled={isBusy || oracleState.phase !== 'Commit' || !provider || !oracle}>
                1. Honest Nodes Commit ({formatUsd(TRUE_PRICE)})
              </button>
              <button className="btn btn-danger" onClick={simulateEclipsedCommits} disabled={isBusy || oracleState.phase !== 'Commit' || !provider || !oracle}>
                2. Eclipsed Nodes Commit ({formatUsd(MALICIOUS_PRICE)})
              </button>
              <button className="btn btn-primary" onClick={simulateHonestReveals} disabled={isBusy || oracleState.phase !== 'Reveal' || !provider || !oracle}>
                3. Honest Nodes Reveal
              </button>
              <button className="btn btn-danger" onClick={simulateEclipsedReveals} disabled={isBusy || oracleState.phase !== 'Reveal' || !provider || !oracle}>
                4. Eclipsed Nodes Reveal
              </button>
              <button className="btn" onClick={triggerCommitTimeout} disabled={isBusy || oracleState.phase !== 'Commit' || !provider || !oracle}>
                🕒 Force Commit Timeout
              </button>
              <button className="btn" onClick={triggerRevealTimeout} disabled={isBusy || oracleState.phase !== 'Reveal' || !provider || !oracle}>
                🕒 Force Reveal Timeout
              </button>
              <button className="btn btn-danger" onClick={executeSlashing} disabled={isBusy || !nodes.some((node) => node.isChallenged) || !provider || !oracle}>
                ⚔️ Execute Slashing (Fast Forward 24h)
              </button>
              <button className="btn btn-danger reset-button" onClick={resetSimulation} disabled={isBusy || !provider}>
                🔄 Reset Simulation (Redeploy Contracts)
              </button>
            </div>
            {isBusy && (
              <p className="pending-message">Running: {pendingAction}</p>
            )}
          </div>
        </>
      )}

      <section className="activity-panel">
        <div className="activity-header">
          <h2>Activity Feed</h2>
          <span>{isBusy ? 'In progress' : 'Idle'}</span>
        </div>
        {logs.length === 0 ? (
          <p className="empty-log">Transactions and contract events will appear here as you run the simulation.</p>
        ) : (
          <div className="activity-list">
            {logs.map((entry) => (
              <div key={entry.id} className="activity-item">
                <span className="activity-time">{entry.timestamp}</span>
                <span className="activity-message">{entry.message}</span>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

export default App;
