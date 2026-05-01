# Deployment trigger

This file is used only to trigger Vercel deployments after connector commits.

Latest trigger purpose: deploy Mindee V2 enqueue guard and disabled auto-OCR helper.

Second trigger: force Vercel to pick up the latest main branch commit chain for the safe Mindee OCR path.

Third trigger: deploy Mindee V2 result polling/save SQL references, fetch/save action, and invoice-review status UI.

Fourth trigger: force production deployment to pick up Mindee result-fetch UI after Vercel did not trigger from the previous connector commit.
