// Define interfaces for the genesis state structure
export interface GenesisState {
  genesis_time: string;
  chain_id: string;
  initial_height: string;
  consensus_params: ConsensusParams;
  app_hash: string;
  app_state: AppState;
}

export interface ConsensusParams {
  block: {
    max_bytes: string;
    max_gas: string;
  };
  evidence: {
    max_age_num_blocks: string;
    max_age_duration: string;
    max_bytes: string;
  };
  validator: {
    pub_key_types: string[];
  };
  version: {
    app: string;
  };
}

export interface AppState {
  assets: AssetsState;
  delegation: DelegationState;
  dogfood: DogfoodState;
  oracle: OracleState;
  // Add other modules as needed
}

export interface AssetsState {
  params: {
    gateways: string[];
  };
  client_chains: ClientChain[];
  tokens: Token[];
  deposits: Deposit[];
  operator_assets: OperatorAsset[];
}

export interface ClientChain {
  name: string;
  meta_info: string;
  finalization_blocks: number;
  layer_zero_chain_id: number;
  address_length: number;
}

export interface Token {
  asset_basic_info: {
    name: string;
    symbol: string;
    address: string;
    decimals: string;
    layer_zero_chain_id: number;
    imua_chain_index: string;
    meta_info: string;
  };
  staking_total_amount: string;
}

export interface Deposit {
  staker: string;
  deposits: {
    asset_id: string;
    info: {
      total_deposit_amount: string;
      withdrawable_amount: string;
      pending_undelegation_amount: string;
    };
  }[];
}

export interface OperatorAsset {
  operator: string;
  assets_state: {
    asset_id: string;
    info: {
      total_amount: string;
      pending_undelegation_amount: string;
      total_share: string;
      operator_share: string;
    };
  }[];
}

export interface DelegationState {
  associations: Association[];
  delegation_states: DelegationStateEntry[];
  stakers_by_operator: StakersByOperator[];
}

export interface Association {
  staker_id: string;
  operator: string;
}

export interface DelegationStateEntry {
  key: string;
  states: {
    undelegatable_share: string;
    wait_undelegation_amount: string;
  };
}

export interface StakersByOperator {
  key: string;
  stakers: string[];
}

export interface DogfoodState {
  params: {
    asset_ids: string[];
    max_validators?: number;
  };
  val_set: Validator[];
  last_total_power: string;
}

export interface Validator {
  public_key: string;
  power: string;
}

export interface OracleState {
  params: {
    tokens: OracleToken[];
    // Add other oracle params as needed
  };
  staker_infos_assets?: StakerInfoAsset[];
  staker_list_assets?: StakerListAsset[];
}

export interface OracleToken {
  name: string;
  chain_id: number;
  contract_address: string;
  active: boolean;
  asset_id: string;
  decimal: number;
}

export interface StakerInfoAsset {
  asset_id: string;
  staker_infos: StakerInfo[];
}

export interface StakerInfo {
  staker_addr: string;
  staker_index: number;
  validator_pubkey_list: string[];
  balance_list: BalanceEntry[];
}

export interface BalanceEntry {
  round_id: number;
  block: number;
  index: number;
  balance: string;
  change: string;
}

export interface StakerListAsset {
  asset_id: string;
  staker_list: {
    staker_addrs: string[];
  };
} 
