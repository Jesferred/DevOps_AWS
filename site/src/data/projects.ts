export interface Project {
  slug: string;
  title: string;
  summary: string;
  stack: string[];
  highlights: string[];
  repo?: string;
  diagram?: 'kovalov-in';
}

export const projects: Project[] = [
  {
    slug: 'kovalov-in',
    title: 'kovalov.in: this site',
    summary:
      'A static site run like a production service: everything in Terraform, keyless CI/CD, edge security headers and a live view of its own reliability and cost.',
    stack: ['AWS Amplify', 'S3', 'ACM', 'Route 53', 'Lambda', 'DynamoDB', 'Terraform', 'GitHub Actions', 'Astro'],
    highlights: [
      'Versioned releases in S3: one-click rollback to any of the last 5 deploys',
      'Synthetic probes from 3 regions feeding a public 99.9% SLO with burn-rate alerts',
      'GitHub Actions authenticates to AWS via OIDC, with no stored keys and approval-gated apply',
      'Remote state with native S3 locking; every change goes through plan in PR',
      'HSTS preload, strict CSP, DNS CAA and DMARC',
    ],
    repo: 'https://github.com/Jesferred/DevOps_AWS',
    diagram: 'kovalov-in',
  },
  {
    slug: 'amplify-pipeline',
    title: 'AWS Amplify CI/CD pipeline',
    summary: 'Front-end delivered through AWS Amplify with automated Jest tests gating every branch.',
    stack: ['AWS Amplify', 'Jest', 'JavaScript'],
    highlights: ['Branch-based environments (test → main)', 'DOM tests with Testing Library in jsdom'],
    repo: 'https://github.com/Jesferred/AWS-amplify-pipeline',
  },
];
