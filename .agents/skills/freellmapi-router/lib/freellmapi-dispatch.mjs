/**
 * Frellmapi Dispatch Integration
 *
 * Provides selective routing between freellmapi (free models) and Claude Opus.
 * Only activated when FRELLMAPI_ROUTING=enabled per-session.
 *
 * Does NOT affect global ANTHROPIC_BASE_URL - routing is per-task.
 */

const DEFAULT_FRELLMAPI_URL = 'http://localhost:3001';

/**
 * Determine if freellmapi routing is enabled for this session
 */
function isRoutingEnabled() {
  return process.env.FRELLMAPI_ROUTING === 'enabled';
}

/**
 * Get the freellmapi gateway URL
 */
function getGatewayUrl() {
  return process.env.FRELLMAPI_URL || DEFAULT_FRELLMAPI_URL;
}

/**
 * Classify task complexity and recommend routing
 *
 * @param {string} effort - low|medium|high|xhigh|max|ultra
 * @param {string} taskType - optional task type descriptor
 * @returns {object} Routing recommendation with harness, model, provider
 */
function recommendRoute(effort = 'medium', taskType = '') {
  const routing = isRoutingEnabled();
  const gatewayUrl = getGatewayUrl();

  // Routing decisions based on effort level
  const decisions = {
    low: {
      route: routing ? 'freellmapi' : 'claude',
      harness: routing ? 'freellmapi' : 'claude',
      model: 'haiku',
      provider: routing ? 'openai' : 'anthropic',
      cost: 0,
      reason: routing
        ? 'Low-effort task routed to freellmapi (free model)'
        : 'Low-effort task on Claude (default)'
    },
    medium: {
      route: routing ? 'freellmapi' : 'claude',
      harness: routing ? 'freellmapi' : 'claude',
      model: 'auto',
      provider: routing ? 'openai' : 'anthropic',
      cost: 0,
      reason: routing
        ? 'Medium task routed to freellmapi with auto model selection'
        : 'Medium task on Claude (default)'
    },
    high:
    case 'xhigh':
    case 'max':
    case 'ultra': {
      return {
        route: 'claude',
        harness: 'claude',
        model: 'opus',
        provider: 'anthropic',
        cost: null, // Tracked via quota-axi
        reason: 'High-effort task on Claude Opus (frontier model)'
      };
    }
  };

  return decisions[effort] || decisions.medium;
}

/**
 * Generate environment variables for a specific route
 *
 * @param {object} recommendation - Route recommendation from recommendRoute()
 * @param {boolean} enableGatewayDiscovery - Enable freellmapi model discovery
 * @returns {object} Environment variables to set
 */
function generateEnvVars(recommendation, enableGatewayDiscovery = true) {
  const env = {};

  if (recommendation.route === 'freellmapi') {
    env.ANTHROPIC_BASE_URL = getGatewayUrl();
    env.ANTHROPIC_MODEL = recommendation.model;
    env.ANTHROPIC_DEFAULT_OPUS_MODEL = recommendation.model;
    env.ANTHROPIC_DEFAULT_SONNET_MODEL = recommendation.model;
    env.ANTHROPIC_DEFAULT_HAIKU_MODEL = recommendation.model;
    env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = '128000';
    if (enableGatewayDiscovery) {
      env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '1';
    }
  } else {
    // Use standard Claude settings (no ANTHROPIC_BASE_URL override)
    env.ANTHROPIC_MODEL = recommendation.model;
    env.ANTHROPIC_DEFAULT_OPUS_MODEL = recommendation.model;
  }

  return env;
}

/**
 * Estimate cost for a task on a given route
 *
 * @param {number} inputTokens - Input token count
 * @param {number} outputTokens - Output token count
 * @param {string} route - freellmapi|claude
 * @returns {number} Estimated USD cost
 */
function estimateCost(inputTokens, outputTokens, route) {
  if (route === 'freellmapi') {
    return 0; // Free LLM API
  }

  // Claude pricing estimates (rough)
  // Opus: ~$0.01 input, ~$0.03 output per 1K tokens
  const inputCost = (inputTokens / 1000) * 0.01;
  const outputCost = (outputTokens / 1000) * 0.03;

  return Math.round((inputCost + outputCost) * 100) / 100;
}

/**
 * Export for use in dispatch pipeline
 */
export {
  isRoutingEnabled,
  getGatewayUrl,
  recommendRoute,
  generateEnvVars,
  estimateCost
};

// CLI interface when run directly
if (import.meta.url === `file://${process.argv[1]}`) {
  const cmd = process.argv[2];

  if (cmd === '--recommend') {
    const effort = process.argv[3] || 'medium';
    const rec = recommendRoute(effort);
    console.log(JSON.stringify(rec, null, 2));
  } else if (cmd === '--env-vars') {
    const effort = process.argv[3] || 'medium';
    const rec = recommendRoute(effort);
    const env = generateEnvVars(rec);
    console.log(JSON.stringify(env, null, 2));
  } else if (cmd === '--estimate') {
    const [input, output, route] = process.argv.slice(3).map((v, i) =>
      i < 2 ? parseInt(v, 10) : v
    );
    console.log(JSON.stringify({ cost: estimateCost(input, output, route) }, null, 2));
  }
}
