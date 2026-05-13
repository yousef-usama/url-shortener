# URL Shortener — Serverless on AWS

A production-grade serverless URL shortener built on AWS.  
Send a long URL, get a short one back. Click the short URL, get redirected instantly.

---

## Architecture

```
                        ┌─────────────────────────────────────────┐
                        │              AWS Cloud                   │
                        │          (eu-central-1)                  │
                        │                                          │
  POST /shorten  ──────►│  API Gateway  ──►  Lambda  ──►  DynamoDB│
  GET  /{code}   ──────►│  (REST API)        (Python)    (NoSQL)  │
                        │                       │                  │
                        │               CloudWatch Logs            │
                        │               CloudWatch Alarms          │
                        └─────────────────────────────────────────┘

  GitHub ──► GitHub Actions ──► terraform apply ──► AWS
              (CI/CD Pipeline)
```

### Components

| Service | Purpose |
|---|---|
| **API Gateway** | HTTP entry point — routes POST /shorten and GET /{code} |
| **Lambda (Python 3.12)** | Business logic — generates codes, reads/writes DynamoDB |
| **DynamoDB** | Stores short_code → long_url mappings (PAY_PER_REQUEST) |
| **CloudWatch Logs** | Captures all Lambda and API Gateway logs (14-day retention) |
| **CloudWatch Alarms** | Alerts on Lambda errors > 5/5min and p99 latency > 3s |
| **IAM** | Least-privilege role — Lambda can only GetItem and PutItem |
| **Terraform** | All infrastructure defined and managed as code |
| **GitHub Actions** | Runs tests on every push, plans on PRs, deploys on merge to main |

---

## API Reference

### Create a short URL

```bash
curl -X POST https://<api-id>.execute-api.eu-central-1.amazonaws.com/prod/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://github.com/yousef-usama"}'
```

**Response (201)**
```json
{
  "short_url": "https://<api-id>.execute-api.eu-central-1.amazonaws.com/prod/Xk39aB2",
  "short_code": "Xk39aB2",
  "long_url": "https://github.com/yousef-usama"
}
```

### Redirect via short code

```bash
curl -L https://<api-id>.execute-api.eu-central-1.amazonaws.com/prod/Xk39aB2
# → 301 redirect to https://github.com/yousef-usama
```

---

## Project Structure

```
url-shortener/
├── lambda/
│   ├── handler.py          # Lambda function (all business logic)
│   └── tests/
│       └── test_handler.py # Unit tests (moto — no real AWS needed)
├── terraform/
│   └── main.tf             # All AWS infrastructure as code
├── .github/
│   └── workflows/
│       └── ci-cd.yml       # GitHub Actions pipeline
├── bootstrap/
│   └── bootstrap.sh        # One-time S3 state bucket setup
└── .gitignore
```

---

## Deployment Guide

### Prerequisites
- AWS CLI configured (`aws sts get-caller-identity` works)
- Terraform >= 1.5 installed (`terraform -v`)
- Python 3.12 installed (`python3 --version`)

### Step 1 — Clone the repo

```bash
git clone https://github.com/yousef-usama/url-shortener.git
cd url-shortener
```

### Step 2 — (Optional) Set up remote state

Stores your Terraform state in S3 instead of locally — recommended.

```bash
bash bootstrap/bootstrap.sh
```

Then uncomment the `backend "s3"` block in `terraform/main.tf` and fill in your account ID.

### Step 3 — Deploy

```bash
cd terraform
terraform init
terraform plan    # review what will be created
terraform apply   # type 'yes' to confirm
```

Terraform will print your API URL when done:
```
api_base_url = "https://abc123.execute-api.eu-central-1.amazonaws.com/prod"
```

### Step 4 — Run tests locally

```bash
pip install pytest boto3 moto
cd lambda
pytest tests/ -v
```

### Step 5 — Set up GitHub Actions

1. Push the repo to GitHub
2. Go to **Settings → Secrets and variables → Actions**
3. Add two secrets:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`

From this point on: every PR triggers `terraform plan` (posted as a comment), every merge to `main` runs `terraform apply` and deploys the Lambda automatically.

### Tear down (avoid charges)

```bash
cd terraform
terraform destroy
```

---

## Key Design Decisions

**Why Lambda + API Gateway instead of EC2?**  
Zero idle cost — you only pay per request. For a personal project with minimal traffic this costs essentially nothing, and it scales automatically if traffic ever spikes.

**Why DynamoDB instead of RDS?**  
URL lookups are pure key-value operations (short_code → long_url). DynamoDB is purpose-built for this pattern — single-digit millisecond reads, no connection pooling needed, and it's free-tier permanent.

**Why PAY_PER_REQUEST billing on DynamoDB?**  
No minimum capacity to provision. At project scale the cost is $0.

**Why least-privilege IAM?**  
The Lambda role only has `dynamodb:GetItem` and `dynamodb:PutItem`. If the function were ever compromised, the blast radius is minimal — it cannot delete, scan, or modify the table schema.

---

## Author

**Yousef Osama** — [LinkedIn](https://www.linkedin.com/in/yousef-usama/) · [GitHub](https://github.com/yousef-usama)  
AWS Certified Solutions Architect – Associate | AWS Certified Cloud Practitioner
