# Pinned to the versions the first unpinned run actually resolved on 2026-09-11.
# Pinning matters more than it looks: Part 14 runs dbt build in GitHub Actions,
# and an image pinned here means local and CI are the same dbt against the same
# adapter. A floating version turns "works on my machine" back into a category
# of failure.
FROM python:3.12-slim

# git is not optional. dbt checks for it unconditionally because dbt deps clones
# packages, and python:3.12-slim ships none -- `dbt debug` reports a failed check
# without it, and `dbt deps` fails outright.
RUN apt-get -qq update \
 && apt-get -qq install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
      dbt-core==1.12.4 \
      dbt-snowflake==1.12.0

WORKDIR /work/dbt
ENTRYPOINT ["dbt"]
CMD ["--version"]
