package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print the version",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "version"
		if jsonOutput {
			return writeJSONSuccess(os.Stdout, "version", map[string]any{
				"version":               versionStr,
				"config_schema_version": 1,
			})
		}
		fmt.Println(versionStr)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}
