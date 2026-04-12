path "kv/data/payments/*" {
  capabilities = ["read"]
}

path "database/creds/payments-wallet" {
  capabilities = ["read"]
}

path "database/creds/payments-transaction" {
  capabilities = ["read"]
}

path "database/creds/payments-query" {
  capabilities = ["read"]
}
