const { synthetics } = require('@aws/synthetics-core');

const checkHttps = async function () {
  const targetUrl = process.env.TARGET_URL;
  const url = new URL(targetUrl);

  const requestOptions = {
    hostname: url.hostname,
    method: 'GET',
    path: `${url.pathname}${url.search}`,
    port: 443,
    protocol: 'https:',
    timeout: 10000,
  };

  // 200-399 means the site answered, including a redirect to a login page.
  // 400 and above, a certificate error, or a timeout fails the check.
  const callback = async (res) => {
    return new Promise((resolve, reject) => {
      const failed = res.statusCode < 200 || res.statusCode > 399;
      res.on('error', reject);
      res.on('end', () => {
        if (failed) {
          reject(new Error(`Unexpected status ${res.statusCode}`));
        } else {
          resolve();
        }
      });
      res.resume();
    });
  };

  await synthetics.executeHttpStep('checkHttps', requestOptions, callback);
};

exports.handler = async () => {
  return await checkHttps();
};
