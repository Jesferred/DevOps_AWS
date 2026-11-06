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
    stack: ['AWS S3', 'CloudFront', 'ACM', 'Route 53', 'Terraform', 'GitHub Actions', 'Astro'],
    highlights: [
      'Private S3 origin, reachable only through CloudFront Origin Access Control',
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
