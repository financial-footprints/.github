# README

This is a meta repository to manage the entire financial footprints project.

## Repository Relationship

```mermaid
flowchart LR
  github[".github<br/>Meta repository for project policies and documentation"]
  dom["NetworthDOM<br/>Browser UI"]
  jwt["NetworthJWT<br/>Issues JWTs / JWKS for auth"]
  db["NetworthDB<br/>Account metadata API"]
  sync["NetworthSync<br/>Exposes the NetworthCSV pipeline over HTTP"]
  csv["NetworthCSV<br/>Parses bank/credit-card PDFs from email into CSV files"]

  dom -->|"login / refresh"| jwt
  dom -->|"Bearer access JWT"| db
  dom -->|"Bearer access JWT"| sync
  db -->|"JWKS"| jwt
  sync -->|"JWKS"| jwt
  sync -->|"account metadata"| db
  db -->|"backup secrets"| sync
  sync --> csv
```

| Repository                                                           | Role                                      |
| -------------------------------------------------------------------- | ----------------------------------------- |
| [.github](https://github.com/financial-footprints/.github)           | Policies, diagram, LICENSE, Bruno e2e     |
| [NetworthJWT](https://github.com/financial-footprints/NetworthJWT)   | Auth service (JWT issue + JWKS)           |
| [NetworthDB](https://github.com/financial-footprints/NetworthHTTP)   | Encrypted account metadata API            |
| [NetworthCSV](https://github.com/financial-footprints/NetworthCSV)   | PDF/email → CSV pipeline                  |
| [NetworthSync](https://github.com/financial-footprints/NetworthSync) | HTTP API over NetworthCSV                 |
| [NetworthDOM](https://github.com/financial-footprints/NetworthDOM)   | Browser UI                                |

## Development

See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for setup, testing, and contribution guidelines.
