import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  experimental: {
    serverActions: {
      // Order creation submits screenshots through a Server Action. The default
      // request limit is too small for multiple normal PNG screenshots.
      bodySizeLimit: "4mb",
    },
  },
};

export default nextConfig;
