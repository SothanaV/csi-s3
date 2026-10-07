package s3

import (
	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
)

var _ = Describe("Config", func() {
	secret := func(skipSSLVerify string) map[string]string {
		return map[string]string{
			"accessKeyID":     "key",
			"secretAccessKey": "secret",
			"region":          "us-east-1",
			"endpoint":        "https://example.com",
			"skipSSLVerify":   skipSSLVerify,
		}
	}

	Describe("skipSSLVerify", func() {
		It("defaults to false when not set", func() {
			client, err := NewClientFromSecret(secret(""))
			Expect(err).NotTo(HaveOccurred())
			Expect(client.Config.SkipSSLVerify).To(BeFalse())
		})

		It("is true when set to true", func() {
			client, err := NewClientFromSecret(secret("true"))
			Expect(err).NotTo(HaveOccurred())
			Expect(client.Config.SkipSSLVerify).To(BeTrue())
		})

		It("is false when set to false", func() {
			client, err := NewClientFromSecret(secret("false"))
			Expect(err).NotTo(HaveOccurred())
			Expect(client.Config.SkipSSLVerify).To(BeFalse())
		})

		It("fails on an invalid value", func() {
			_, err := NewClientFromSecret(secret("yes-please"))
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("skipSSLVerify"))
		})
	})
})
